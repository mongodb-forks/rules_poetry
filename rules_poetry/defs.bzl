"Poetry rule definitions"

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

# We no longer need to use this due to updates to rules_python, but we have not erased it for backward compatibility.
def deterministic_env():
    return {
        # lifted from https://github.com/bazelbuild/rules_python/issues/154
        "CFLAGS": "-g0",  # debug symbols contain non-deterministic file paths
        "PATH": "/bin:/usr/bin:/usr/local/bin",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONHASHSEED": "0",
        "SOURCE_DATE_EPOCH": "315532800",  # set wheel timestamps to 1980-01-01T00:00:00Z
        "USERPROFILE":".",
    }

def poetry_deps():
    
    http_archive(
        name = "wheel_archive",
        sha256 = "7a5a3095dceca97a3cac869b8fef4e89b83fafde21b6688f47b6fda7600eb441",
        urls = ["https://files.pythonhosted.org/packages/46/3a/73fcaf6487aa9a9b02ee9df30a24bdc2c1f0292fe559811936d67a9053c1/wheel-0.38.2-py3-none-any.whl"],
        build_file_content = """
load("@rules_python//python:defs.bzl", "py_library")

py_library(
    name = "wheel",
    imports = ["wheel"],
    srcs = glob(["wheel/**/*.py"]),
    data = glob(["wheel/**/*"], exclude=["**/*.py", "**/* *", "BUILD", "WORKSPACE"]),
    visibility = ["//visibility:public"],
)
        """,
        type = "zip",
        workspace_file_content = "",
    )

    http_archive(
        name = "setuptools_archive",
        sha256 = "6afa61b391dcd16cb8890ec9f66cc4015a8a31a6e1c2b4e0c464514be1a3d722",
        urls = ["https://files.pythonhosted.org/packages/11/0a/7f13ef5cd932a107cd4c0f3ebc9d831d9b78e1a0e8c98a098ca17b1d7d97/setuptools-41.6.0.zip"],
        build_file_content = """
load("@rules_python//python:defs.bzl", "py_library")

py_library(
    name = "setuptools",
    imports = ["setuptools"],
    srcs = glob(["setuptools/**/*.py"]),
    data = glob(["setuptools/**/*"], exclude=["**/*.py", "**/* *", "BUILD", "WORKSPACE"]),
    visibility = ["//visibility:public"],
)
        """,
        workspace_file_content = "",
    )

WheelInfo = provider(fields = [
    "pkg",
    "version",
    "marker",
])

def _render_requirements(ctx):
    destination = ctx.actions.declare_file("requirements/%s.txt" % ctx.attr.name)
    marker = ctx.attr.marker
    if marker:
        marker = "; " + marker

    content = "{name}=={version} {hashes} {marker}".format(
        name = ctx.attr.pkg,
        version = ctx.attr.version,
        hashes = " ".join(["--hash=" + h for h in ctx.attr.hashes]),
        marker = marker,
    )
    ctx.actions.write(
        output = destination,
        content = content,
        is_executable = False,
    )

    return destination

COMMON_ARGS = [
    "--quiet",
    "--no-deps",
    "--use-pep517",
    "--disable-pip-version-check",
    "--no-cache-dir",
    "--isolated",
]

def _download(ctx, requirements):

    toolchain = ctx.toolchains["@bazel_tools//tools/python:toolchain_type"]
    runtime = toolchain.py3_runtime
    inputs = depset([requirements], transitive = [runtime.files])
    tools = depset(direct = [runtime.interpreter], transitive = [runtime.files])

    python = ctx.toolchains["@bazel_tools//tools/python:toolchain_type"].py3_runtime
    destination = ctx.actions.declare_file("wheels/%s/%s.whl" % (ctx.attr.name,ctx.attr.name))
    args = ctx.actions.args()
    args.add(ctx.attr._wheel_wrapper.files.to_list()[0].path)
    args.add(destination.path)
    args.add("-m")
    args.add("pip")
    args.add("wheel")
    args.add_all(COMMON_ARGS)
    args.add("--require-hashes")
    args.add("--wheel-dir")
    args.add(destination.dirname)
    args.add("-r")
    args.add(requirements)
    if ctx.attr.source_url != "":
        args.add("-i")
        args.add(ctx.attr.source_url)

    ctx.actions.run(
        executable = python.interpreter.path,
        inputs = inputs,
        outputs = [destination],
        arguments = [args],
        env = deterministic_env(),
        mnemonic = "DownloadWheel",
        progress_message = "Collecting %s wheel from pypi" % ctx.attr.pkg,
        execution_requirements = {
            "requires-network": "",
        },
        tools = tools,
    )

    return destination

def _download_wheel_impl(ctx):
    requirements = _render_requirements(ctx)
    wheel_directory = _download(ctx, requirements)

    return [
        DefaultInfo(
            files = depset([wheel_directory]),
            runfiles = ctx.runfiles(
                files = [wheel_directory],
                collect_default = True,
            ),
        ),
        WheelInfo(
            pkg = ctx.attr.pkg,
            version = ctx.attr.version,
            marker = ctx.attr.marker,
        ),
    ]

download_wheel = rule(
    implementation = _download_wheel_impl,
    attrs = {
        "pkg": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "hashes": attr.string_list(mandatory = True, allow_empty = False),
        "marker": attr.string(mandatory = True),
        "source_url": attr.string(mandatory = True),
        "_wheel_wrapper": attr.label(default="//:wheel_wrapper.py", allow_single_file=True
    },
    toolchains = ["@bazel_tools//tools/python:toolchain_type"],
)

def _install(ctx, wheel_info):
    
    installed_wheel = ctx.actions.declare_directory(wheel_info.pkg)
    python = ctx.toolchains["@bazel_tools//tools/python:toolchain_type"].py3_runtime
    
    args = [
        "-m",
        "pip",
        'install', 
        '--force-reinstall',
        '--upgrade',
    ] + COMMON_ARGS + [
        "--no-compile",
        "--no-index",
        "--find-links",
        ctx.files.wheel[0].path,
        "--target="+installed_wheel.path,
        wheel_info.pkg + " ; " + str(wheel_info.marker)
    ]

    ctx.actions.run(
        executable = python.interpreter.path,
        outputs = [installed_wheel],
        inputs = depset(ctx.files.wheel, transitive = [python.files]),
        arguments = args,
        env = deterministic_env(),
        progress_message = "Installing %s wheel" % wheel_info.pkg,
        mnemonic = "CopyWheel",
    )
    
    return installed_wheel

def _pip_install_impl(ctx):
    w = ctx.attr.wheel
    wheel_info = w[WheelInfo]
    wheel = _install(ctx, wheel_info)

    return [
        DefaultInfo(
            files = depset([wheel]),
            runfiles = ctx.runfiles(
                files = [wheel],
                collect_default = True,
            ),
        ),
        PyInfo(
            transitive_sources = depset([wheel]),
        ),
    ]

pip_install = rule(
    implementation = _pip_install_impl,
    attrs = {
        "wheel": attr.label(mandatory = True, providers = [WheelInfo]),
    },
    toolchains = ["@bazel_tools//tools/python:toolchain_type"],
)

def _noop_impl(ctx):
    return []

noop = rule(
    implementation = _noop_impl,
    doc = "Rule for excluded packages",
)
