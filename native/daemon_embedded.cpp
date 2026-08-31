extern "C" {
#include <rtsyn/runtime.h>
#include <rtsyn/runtime/config.h>
#include <rtsyn/spsc/defaults.h>
}

#include <rtsyn/api.hpp>
#include <rtsyn/api/defaults.h>
#include <rtsyn/engine.h>

#include <atomic>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <sys/prctl.h>
#include <thread>
#include <unistd.h>

namespace {

std::atomic_bool stop_requested{false};

void
handle_signal(int)
{
    stop_requested.store(true, std::memory_order_relaxed);
}

const char *
env_or_default(const char *name, const char *default_value)
{
    const char *value = std::getenv(name);
    return value && value[0] != '\0' ? value : default_value;
}

bool
parse_env_ulong(const char *name, unsigned long *result)
{
    const char *value = std::getenv(name);
    if (!value || value[0] == '\0' || !result)
    {
        return false;
    }

    errno = 0;
    char *end = nullptr;
    const unsigned long parsed = std::strtoul(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0')
    {
        std::fprintf(stderr, "rtsyn daemon: invalid %s value '%s'\n", name, value);
        return false;
    }

    *result = parsed;
    return true;
}

bool
configure_rt_cpu_from_env(rtsyn_engine_config_t *config)
{
    const char *value = std::getenv("RTSYN_RT_CPU");
    if (!value || value[0] == '\0')
    {
        return true;
    }

    unsigned long cpu = 0;
    if (!parse_env_ulong("RTSYN_RT_CPU", &cpu))
    {
        return false;
    }

    const long online_cpus = sysconf(_SC_NPROCESSORS_ONLN);
    if (cpu >= CPU_SETSIZE || online_cpus <= 0 || cpu >= static_cast<unsigned long>(online_cpus))
    {
        std::fprintf(stderr, "rtsyn daemon: RTSYN_RT_CPU=%lu is not an online CPU\n", cpu);
        return false;
    }

    CPU_ZERO(&config->rt_thread.cpuset);
    CPU_SET(static_cast<int>(cpu), &config->rt_thread.cpuset);
    config->rt_thread.use_affinity = true;
    return true;
}

unsigned long
configure_rt_timer_slack()
{
    constexpr unsigned long default_slack_ns = 1;
    unsigned long requested_slack_ns = default_slack_ns;
    const char *configured = std::getenv("RTSYN_RT_TIMER_SLACK_NS");
    if (configured && configured[0] != '\0'
        && !parse_env_ulong("RTSYN_RT_TIMER_SLACK_NS", &requested_slack_ns))
    {
        requested_slack_ns = default_slack_ns;
    }

    // Linux interprets zero as "restore the process default", not zero slack.
    if (requested_slack_ns == 0)
    {
        requested_slack_ns = default_slack_ns;
    }

    const int previous_slack_ns = prctl(PR_GET_TIMERSLACK);
    if (previous_slack_ns < 0
        || prctl(PR_SET_TIMERSLACK, requested_slack_ns, 0UL, 0UL, 0UL) != 0)
    {
        std::fprintf(stderr, "rtsyn daemon: warning: failed to reduce RT timer slack\n");
        return 0;
    }
    return static_cast<unsigned long>(previous_slack_ns);
}

struct Endpoint {
    std::string host = RTSYN_API_DEFAULT_HOST;
    int port = RTSYN_API_DEFAULT_PORT;
};

Endpoint
parse_endpoint(const char *api_base_url)
{
    Endpoint endpoint;
    if (!api_base_url || api_base_url[0] == '\0')
    {
        return endpoint;
    }

    std::string url(api_base_url);
    const std::string scheme = "://";
    const auto scheme_pos = url.find(scheme);
    if (scheme_pos != std::string::npos)
    {
        url = url.substr(scheme_pos + scheme.size());
    }

    const auto slash_pos = url.find('/');
    if (slash_pos != std::string::npos)
    {
        url.resize(slash_pos);
    }

    const auto colon_pos = url.rfind(':');
    if (colon_pos == std::string::npos)
    {
        endpoint.host = url.empty() ? RTSYN_API_DEFAULT_HOST : url;
        return endpoint;
    }

    endpoint.host = url.substr(0, colon_pos);
    const std::string port_text = url.substr(colon_pos + 1);
    const int port = std::atoi(port_text.c_str());
    if (port > 0)
    {
        endpoint.port = port;
    }
    if (endpoint.host.empty())
    {
        endpoint.host = RTSYN_API_DEFAULT_HOST;
    }
    return endpoint;
}

void
close_shared_queues(rtsyn_spsc_command_shared_t *command_shared,
                    rtsyn_spsc_result_shared_t *result_shared,
                    rtsyn_spsc_telemetry_shared_t *telemetry_shared,
                    rtsyn_spsc_telemetry_values_shared_t *values_shared)
{
    rtsyn_spsc_command_shared_close(command_shared);
    rtsyn_spsc_result_shared_close(result_shared);
    rtsyn_spsc_telemetry_shared_close(telemetry_shared);
    rtsyn_spsc_telemetry_values_shared_close(values_shared);
}

void
unlink_shared_queues(const char *command_name, const char *result_name,
                     const char *telemetry_name, const char *values_name)
{
    (void)rtsyn_spsc_command_shared_unlink(command_name);
    (void)rtsyn_spsc_result_shared_unlink(result_name);
    (void)rtsyn_spsc_telemetry_shared_unlink(telemetry_name);
    (void)rtsyn_spsc_telemetry_values_shared_unlink(values_name);
}

} // namespace

extern "C" int
rtsyn_embedded_daemon_run(const char *api_base_url)
{
    stop_requested.store(false, std::memory_order_relaxed);
    std::signal(SIGINT, handle_signal);
    std::signal(SIGTERM, handle_signal);
#ifdef SIGHUP
    std::signal(SIGHUP, SIG_IGN);
#endif

    rtsyn_runtime_config_t runtime_config = {};
    rtsyn_runtime_config_init(&runtime_config);

    rtsyn_runtime_t *runtime = rtsyn_runtime_create(&runtime_config);
    if (!runtime)
    {
        std::fprintf(stderr, "rtsyn daemon: failed to create runtime\n");
        return EXIT_FAILURE;
    }

    const char *command_name =
        env_or_default(RTSYN_SPSC_ENV_COMMAND_QUEUE, RTSYN_SPSC_DEFAULT_COMMAND_QUEUE);
    const char *result_name =
        env_or_default(RTSYN_SPSC_ENV_RESULT_QUEUE, RTSYN_SPSC_DEFAULT_RESULT_QUEUE);
    const char *telemetry_name =
        env_or_default(RTSYN_SPSC_ENV_TELEMETRY_QUEUE, RTSYN_SPSC_DEFAULT_TELEMETRY_QUEUE);
    const char *values_name = env_or_default(RTSYN_SPSC_ENV_TELEMETRY_VALUES_QUEUE,
                                             RTSYN_SPSC_DEFAULT_TELEMETRY_VALUES_QUEUE);

    unlink_shared_queues(command_name, result_name, telemetry_name, values_name);

    rtsyn_spsc_command_shared_t command_shared = {};
    rtsyn_spsc_result_shared_t result_shared = {};
    rtsyn_spsc_telemetry_shared_t telemetry_shared = {};
    rtsyn_spsc_telemetry_values_shared_t values_shared = {};
    if (rtsyn_spsc_command_shared_create(&command_shared, command_name) != 0
        || rtsyn_spsc_result_shared_create(&result_shared, result_name) != 0
        || rtsyn_spsc_telemetry_shared_create(&telemetry_shared, telemetry_name) != 0
        || rtsyn_spsc_telemetry_values_shared_create(&values_shared, values_name) != 0)
    {
        std::fprintf(stderr, "rtsyn daemon: failed to create SPSC shared queues\n");
        close_shared_queues(&command_shared, &result_shared, &telemetry_shared, &values_shared);
        unlink_shared_queues(command_name, result_name, telemetry_name, values_name);
        rtsyn_runtime_destroy(runtime);
        return EXIT_FAILURE;
    }

    rtsyn_engine_config_t engine_config = {};
    rtsyn_engine_config_init(&engine_config);
    engine_config.runtime = runtime;
    engine_config.command_queue = command_shared.queue;
    engine_config.result_queue = result_shared.queue;
    engine_config.telemetry_queue = telemetry_shared.queue;
    engine_config.telemetry_values = values_shared.values;
    if (!configure_rt_cpu_from_env(&engine_config))
    {
        close_shared_queues(&command_shared, &result_shared, &telemetry_shared, &values_shared);
        unlink_shared_queues(command_name, result_name, telemetry_name, values_name);
        rtsyn_runtime_destroy(runtime);
        return EXIT_FAILURE;
    }

    rtsyn_engine_t *engine = rtsyn_engine_create(&engine_config);
    if (!engine)
    {
        std::fprintf(stderr, "rtsyn daemon: failed to create engine\n");
        close_shared_queues(&command_shared, &result_shared, &telemetry_shared, &values_shared);
        unlink_shared_queues(command_name, result_name, telemetry_name, values_name);
        rtsyn_runtime_destroy(runtime);
        return EXIT_FAILURE;
    }
    // Timer slack is inherited by newly-created pthreads. Tighten it while the
    // engine creates its RT/wait threads, then restore the daemon thread so the
    // HTTP side can retain normal timer coalescing behavior.
    const unsigned long previous_timer_slack_ns = configure_rt_timer_slack();
    const bool engine_started = rtsyn_engine_start(engine);
    if (previous_timer_slack_ns > 0)
    {
        (void)prctl(PR_SET_TIMERSLACK, previous_timer_slack_ns, 0UL, 0UL, 0UL);
    }
    if (!engine_started)
    {
        std::fprintf(stderr,
                     "rtsyn daemon: failed to start engine RT threads; check realtime permissions\n");
        rtsyn_engine_destroy(engine);
        close_shared_queues(&command_shared, &result_shared, &telemetry_shared, &values_shared);
        unlink_shared_queues(command_name, result_name, telemetry_name, values_name);
        rtsyn_runtime_destroy(runtime);
        return EXIT_FAILURE;
    }

    const Endpoint endpoint = parse_endpoint(api_base_url);
    rtsyn::api::Config api_config;
    api_config.command_queue = command_shared.queue;
    api_config.result_queue = result_shared.queue;
    api_config.telemetry_queue = telemetry_shared.queue;
    api_config.telemetry_values = values_shared.values;
    api_config.bind_host = endpoint.host;
    api_config.port = endpoint.port;
    api_config.values_path = env_or_default(RTSYN_API_ENV_VALUES_FILE,
                                            RTSYN_API_DEFAULT_VALUES_FILE);

    auto api = std::make_unique<rtsyn::api::Api>(api_config);
    if (!api->start())
    {
        std::fprintf(stderr, "rtsyn daemon: failed to start HTTP API at %s:%d\n",
                     endpoint.host.c_str(), endpoint.port);
        rtsyn_engine_request_stop(engine);
        (void)rtsyn_engine_join(engine);
        rtsyn_engine_destroy(engine);
        close_shared_queues(&command_shared, &result_shared, &telemetry_shared, &values_shared);
        unlink_shared_queues(command_name, result_name, telemetry_name, values_name);
        rtsyn_runtime_destroy(runtime);
        return EXIT_FAILURE;
    }

    while (!stop_requested.load(std::memory_order_relaxed) && rtsyn_engine_is_running(engine))
    {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    api->stop();
    api.reset();
    rtsyn_engine_request_stop(engine);
    const bool joined = rtsyn_engine_join(engine);
    rtsyn_engine_destroy(engine);
    close_shared_queues(&command_shared, &result_shared, &telemetry_shared, &values_shared);
    unlink_shared_queues(command_name, result_name, telemetry_name, values_name);
    rtsyn_runtime_destroy(runtime);

    return joined ? EXIT_SUCCESS : EXIT_FAILURE;
}
