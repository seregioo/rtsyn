local project_name = "rtsyn"
local project_xmake_repo = "rtsyn-xmake-repo"

set_license("GPL-3.0-or-later")

add_rules("mode.debug", "mode.release")
set_defaultmode("release")

local cargo = "cargo"
option("thread_core")
set_default("posix")
set_values("posix", "preempt_rt", "xenomai")
set_showmenu(true)
set_description("Thread core backend", "  - posix", "  - preempt_rt", "  - xenomai")
option_end()

local workspace = os.getenv("RTSYN_WORKSPACE")
if workspace then
    local repository_dir = path.join(workspace, project_xmake_repo)
    add_repositories(project_xmake_repo .. " " .. repository_dir)
else
    add_repositories(project_xmake_repo .. " https://github.com/seregioo/" .. project_xmake_repo .. ".git")
end

local thread_core = get_config("thread_core") or "posix"
local rust_dependencies = { "rtsyn-ui" }
local native_dependencies = {
    "rtsyn-api",
    "rtsyn-engine",
    "rtsyn-runtime",
    "rtsyn-thread",
    "rtsyn-spsc",
    "rtsyn-node",
    "rtsyn-port",
    "rtsyn-value",
    "rtsyn-abi",
    "rtsyn-collection",
    "rtsyn-module-loader",
    "rtsyn-measurement-tool",
    "rtsyn-defaults",
    "cpp-httplib",
    "libuv",
}
if workspace then
    add_requires("cpp-httplib", "libuv")
else
    add_requires("rtsyn-ui", { configs = { thread_core = thread_core } })
    add_requires("rtsyn-api", { configs = { package_layout = "library" } })
    add_requires("rtsyn-engine", { configs = { thread_core = thread_core, package_layout = "library" } })
    add_requires("rtsyn-runtime", { configs = { thread_core = thread_core } })
    add_requires("rtsyn-thread", { configs = { thread_core = thread_core } })
    add_requires("rtsyn-spsc", "rtsyn-node", "rtsyn-port", "rtsyn-value", "rtsyn-abi",
                 "rtsyn-collection", "rtsyn-module-loader", "rtsyn-measurement-tool",
                 "rtsyn-defaults", "cpp-httplib", "libuv")
end

target(project_name)
set_kind("binary")
set_default(true)
set_targetdir(path.join(os.projectdir(), "build", "$(plat)", "$(arch)", "$(mode)"))
add_files("xmake/run_rtsyn.rs")
if workspace then
    add_packages("cpp-httplib", "libuv")
else
    add_packages(rust_dependencies)
    add_packages(native_dependencies)
end

local function cargo_profile()
    if is_mode("release") then
        return "release"
    end
    return "debug"
end

local function cargo_binary()
    return path.join(os.projectdir(), "target", cargo_profile(), project_name)
end

local native_workspace_modules = {
    "rtsyn-api",
    "rtsyn-engine",
    "rtsyn-runtime",
    "rtsyn-thread",
    "rtsyn-spsc",
    "rtsyn-node",
    "rtsyn-port",
    "rtsyn-value",
    "rtsyn-abi",
    "rtsyn-collection",
    "rtsyn-module-loader",
    "rtsyn-measurement-tool",
    "rtsyn-defaults",
}

local function native_workspace_builddir(module_name)
    return path.join(workspace, module_name, "build", get_config("plat") or os.host(),
                     get_config("arch") or os.arch(), cargo_profile())
end

local function workspace_paths(scope)
    if not workspace then
        return ""
    end
    local values = {}
    for _, module_name in ipairs(native_workspace_modules) do
        local candidate
        if scope == "include" then
            candidate = path.join(workspace, module_name, "include")
        else
            candidate = native_workspace_builddir(module_name)
        end
        if candidate and os.isdir(candidate) then
            table.insert(values, candidate)
        end
    end
    return table.concat(values, path.envsep())
end

local function append_unique(values, value)
    if value and value ~= "" and os.isdir(value) then
        for _, existing in ipairs(values) do
            if existing == value then
                return
            end
        end
        table.insert(values, value)
    end
end

local function package_paths(target, package_names, scope)
    local values = {}
    for _, package_name in ipairs(package_names) do
        local package = target:pkg(package_name)
        if package then
            append_unique(values, path.join(package:installdir(), scope))
        end
    end
    return table.concat(values, path.envsep())
end

local function join_path_lists(...)
    local values = {}
    for _, value in ipairs({ ... }) do
        if value and value ~= "" then
            table.insert(values, value)
        end
    end
    return table.concat(values, path.envsep())
end

local function cargo_envs(target)
    local include_dirs = package_paths(target, { "cpp-httplib", "libuv" }, "include")
    local lib_dirs = package_paths(target, { "libuv" }, "lib")
    if workspace then
        include_dirs = join_path_lists(workspace_paths("include"), include_dirs)
        lib_dirs = join_path_lists(workspace_paths("lib"), lib_dirs)
    else
        include_dirs = package_paths(target, native_dependencies, "include")
        lib_dirs = package_paths(target, native_dependencies, "lib")
    end
    return {
        RTSYN_WORKSPACE = workspace,
        RTSYN_THREAD_CORE = thread_core,
        RTSYN_NATIVE_INCLUDE_DIRS = include_dirs,
        RTSYN_NATIVE_LIB_DIRS = lib_dirs,
        RTSYN_NATIVE_LIBS = "rtsyn-api,rtsyn-engine,rtsyn-runtime,rtsyn-spsc,rtsyn-node,rtsyn-port,rtsyn-value,rtsyn-abi,rtsyn-collection,rtsyn-module-loader,rtsyn-measurement-tool,rtsyn-thread,uv",
    }
end

before_build(function(target)
    if workspace then
        local mode = is_mode("release") and "release" or "debug"
        local workspace_builder = path.join(workspace, project_xmake_repo, "includes",
                                            "rtsyn_workspace.lua")
        local external_includes = package_paths(target, { "cpp-httplib", "libuv" }, "include")
        os.vrunv(os.programfile(),
                 { "lua", workspace_builder, workspace, mode, thread_core,
                   external_includes })
    end

    local args = { "build", "--bin", project_name }
    if workspace then
        table.insert(args, "--config")
        table.insert(args, "patch.\"https://github.com/seregioo/rtsyn-ui.git\".rtsyn-ui.path=\"" .. path.join(workspace, "rtsyn-ui") .. "\"")
    end
    if is_mode("release") then
        table.insert(args, "--release")
    end

    os.vrunv(cargo, args, { envs = cargo_envs(target) })
end)

after_build(function(target)
    os.vrunv("cp", { "-f", cargo_binary(), target:targetfile() })
end)

target("tests/rtsyn-tests")
set_kind("binary")
set_default(false)
set_targetdir(path.join(os.projectdir(), "build", "$(plat)", "$(arch)", "$(mode)"))
add_files("xmake/tests_runner.rs")
add_tests("rust-tests")
