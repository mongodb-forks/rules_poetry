"Poetry utility functions"

# Because Poetry doesn't add several packages in the poetry.lock file,
# they are excluded from the list of packages.
# See https://github.com/python-poetry/poetry/blob/d2fd581c9a856a5c4e60a25acb95d06d2a963cf2/poetry/puzzle/provider.py#L55
# and https://github.com/python-poetry/poetry/issues/1584
POETRY_UNSAFE_PACKAGES = ["setuptools", "distribute", "pip", "wheel"]

# normally _ would be a delimiter, but these values can include it in the name
# next would normally be : but bazel uses this in target names
# so finally we settle on ! for a delimiter in this case.
# this values from https://peps.python.org/pep-0496/#strings
SUPPORTED_PLATFORMS = [
    "linux!s390x",
    "linux!ppc64le",
    "linux!aarch64",
    "linux!x86_64",
    "darwin!aarch64",
    "darwin!x86_64",
    "win32!x86_64",
]

def _clean_name(name):
    return name.lower().replace("-", "_").replace(".", "_")

def _get_python_interpreter_attr(rctx):
    if rctx.attr.python_interpreter:
        return rctx.attr.python_interpreter

    if "win" in rctx.os.name:
        return "python.exe"
    else:
        return "python3"

def _resolve_python_interpreter(rctx):
    python_interpreter = _get_python_interpreter_attr(rctx)

    if "win" in rctx.os.name:
        interpreter_target = rctx.attr.python_interpreter_target_win
    elif "mac" in rctx.os.name:
        interpreter_target = rctx.attr.python_interpreter_target_mac
    else:
        # we are referring to a bazel file target and just use the default location
        # the the file might be.
        interpreter_target = rctx.attr.python_interpreter_target_default

    if interpreter_target:
        # interpreter_target represent a bazel file target, and most likely
        # is coming from some part of the current bazel build. The other option
        # available for selecting the interpretor would be a raw path string
        # pointing to something that should be installed on the system, for
        # example /usr/bin/python
        if rctx.attr.python_interpreter:
            fail("interpreter_target and python_interpreter incompatible")

        python_interpreter = rctx.path(interpreter_target)

        return python_interpreter

    if "/" not in python_interpreter:
        python_interpreter = rctx.which(python_interpreter)

    if not python_interpreter:
        fail("python interpreter `{}` not found in PATH".format(python_interpreter))

    return python_interpreter

def _mapping(repository_ctx):
    python_interpreter = _resolve_python_interpreter(repository_ctx)
    result = repository_ctx.execute(
        [
            python_interpreter,
            repository_ctx.path(repository_ctx.attr._script),
            "-i",
            repository_ctx.path(repository_ctx.attr.pyproject),
            "-o",
            "-",
            "--if",
            "toml",
            "--of",
            "json",
        ],
    )

    if result.return_code:
        fail("remarshal failed: %s (%s)" % (result.stdout, result.stderr))

    pyproject = json.decode(result.stdout)

    def unpack_dependencies(x):
        return {
            dep.lower(): "@%s//:library_%s" % (repository_ctx.name, _clean_name(dep))
            for dep in x.keys()
        }

    dependencies = unpack_dependencies(pyproject["tool"]["poetry"]["dependencies"])

    groups = {}

    for k, v in pyproject["tool"]["poetry"].get("group", {}).items():
        groups.update({
            k: unpack_dependencies(v["dependencies"]),
        })

    return {
        "dependencies": dependencies,
        "groups": groups,
        "pyproject": pyproject,
    }

def extract_markers(repository_ctx, resolved_markers, dep, markers):
    python_interpreter = _resolve_python_interpreter(repository_ctx)

    # the passed arg "markers" may not actually be a marker. It could be just a
    # version string. So we check if its a type which could support markers
    if str(type(markers)) != "list" and str(type(markers)) != "dict":
        return

    # sometimes markers are not in list form if there is only one marker. We make
    # it a list so the code path below is the same.
    if str(type(markers)) == "dict":
        markers = [markers]

    for marker in markers:
        marker_string = marker.get("markers", "")
        if marker_string:
            # we found a marker so add it to the aggregate list of found markers
            if dep not in resolved_markers:
                resolved_markers[dep] = {}

            # test each platform to see if the marker shows support for it
            for platform in SUPPORTED_PLATFORMS:
                system, machine = platform.split("!")

                # Here we construct the code string we want to evaluate as a conditional
                # for example:
                #   * the input string (e.g.: "platform_machine == 's390x' or platform_machine == 'ppc64le'")
                #   * output code string (e.g.: "'macos' == 's390x' or 'macos' == 'ppc64le'")
                #   * the eval result of the code string is "False", macos is not supported
                #     for the version related to the code string.
                test_string = marker_string.replace("platform_machine", "'" + machine + "'")
                test_string = test_string.replace("sys_platform", "'" + system + "'")
                cmd = [
                    python_interpreter,
                    "-c",
                    "print(" + test_string + ")",
                ]
                result = repository_ctx.execute(cmd)
                if result.stdout.strip() == str(True):
                    # if the marker gave True for the platform strings under test,
                    # we save the platform to the current version
                    marker_version = marker["version"]
                    if marker_version not in resolved_markers[dep]:
                        resolved_markers[dep][marker_version] = []
                    resolved_markers[dep][marker_version].append(platform)

def _impl(repository_ctx):
    python_interpreter = _resolve_python_interpreter(repository_ctx)
    mapping = _mapping(repository_ctx)

    result = repository_ctx.execute(
        [
            python_interpreter,
            repository_ctx.path(repository_ctx.attr._script),
            "-i",
            repository_ctx.path(repository_ctx.attr.lockfile),
            "-o",
            "-",
            "--if",
            "toml",
            "--of",
            "json",
        ],
    )

    if result.return_code:
        fail("remarshal failed: %s (%s)" % (result.stdout, result.stderr))

    lockfile = json.decode(result.stdout)
    metadata = lockfile["metadata"]
    if "files" in metadata:  # Poetry 1.x format
        files = metadata["files"]

        # only the hashes are needed to build a requirements.txt
        hashes = {
            k: [x["hash"] for x in v]
            for k, v in files.items()
        }
    elif "hashes" in metadata:  # Poetry 0.x format
        hashes = ["sha256:" + h for h in metadata["hashes"]]
    elif metadata["lock-version"] in ["2.0"]:
        hashes = {}
        for package in lockfile["package"]:
            key = package["name"]
            if key not in hashes:
                hashes[key] = []
            hashes[key] += [pack["hash"] for pack in package["files"]]
    else:
        fail("Did not find file hashes in poetry.lock file")

    # using a `dict` since there is no `set` type
    excludes = {x.lower(): True for x in repository_ctx.attr.excludes + POETRY_UNSAFE_PACKAGES}
    for requested in mapping:
        if requested.lower() in excludes:
            fail("pyproject.toml dependency {} is also in the excludes list".format(requested))

    toml_markers = {}
    if metadata["lock-version"] in ["2.0"]:
        poetry_dict = mapping.get("pyproject", {}).get("tool", {}).get("poetry")
        if poetry_dict:
            for dep, markers in poetry_dict.get("dependencies", {}).items():
                extract_markers(repository_ctx, toml_markers, dep, markers)

            for _, group in poetry_dict.get("group", {}).items():
                for dep, markers in group.get("dependencies", {}).items():
                    extract_markers(repository_ctx, toml_markers, dep, markers)

    packages = []
    package_names = []
    for package in lockfile["package"]:
        name = package["name"]

        if name.lower() in excludes:
            continue

        if "source" in package and package["source"]["type"] != "legacy":
            # TODO: figure out how to deal with git and directory refs
            print("Skipping " + name)
            continue

        if _clean_name(name) in package_names:
            continue

        version_select = '"' + package["version"] + '"'
        if name in toml_markers:
            version_select = "select({\n"
            for version in toml_markers[name]:
                for platform in toml_markers[name][version]:
                    system, machine = platform.split("!")
                    version_select += "        ':{system}!{machine}':'{version}',\n".format(system = system, machine = machine, version = version)
            version_select += "    })"

        package_names.append(_clean_name(name))
        packages.append(struct(
            name = _clean_name(name),
            pkg = name,
            version = version_select,
            hashes = hashes[name],
            marker = package.get("marker", None),
            source_url = package.get("source", {}).get("url", None),
            dependencies = [
                _clean_name(name)
                for name in package.get("dependencies", {}).keys()
                if name.lower() not in excludes
            ],
        ))

    repository_ctx.file(
        "dependencies.bzl",
        """
_mapping = {mapping}

def dependency(name, group = None):
    if group:
        if group not in _mapping["groups"]:
            fail("%s is not a group in pyproject.toml" % name)

        dependencies = _mapping["groups"][group]

        if name not in dependencies:
            fail("%s is not present in group %s in pyproject.toml" % (name, group))

        return dependencies[name]

    dependencies = _mapping["dependencies"]

    if name not in dependencies:
        fail("%s is not present in pyproject.toml" % name)

    return dependencies[name]
""".format(mapping = mapping),
    )

    repository_ctx.symlink(repository_ctx.path(repository_ctx.attr._rules), repository_ctx.path("defs.bzl"))
    repository_ctx.file(
        "wheel_wrapper.py",
        """
import sys
import subprocess
import os
import shutil

wheel_file = sys.argv[1]
wheel_dir = os.path.dirname(wheel_file)
args = sys.argv[2:]
shutil.rmtree(wheel_dir)
os.makedirs(wheel_dir, exist_ok=True)
subprocess.run([sys.executable] + args)
real_wheel = os.listdir(wheel_dir)[0]
real_wheel = os.path.join(wheel_dir, real_wheel)
os.link(real_wheel, wheel_file)
"""
    )
    poetry_template = """
download_wheel(
    name = "wheel_{name}",
    pkg = "{pkg}",
    version = {version},
    hashes = {hashes},
    marker = "{marker}",
    source_url = "{source_url}",
    visibility = ["//visibility:private"],
    tags = [{download_tags}, "requires-network"],
)

pip_install(
    name = "install_{name}",
    wheel = ":wheel_{name}",
    tags = [{install_tags}],
)

py_library(
    name = "library_{name}",
    srcs = glob(["{pkg}/**/*.py"]),
    data = glob(["{pkg}/**/*"], exclude=["**/*.py", "**/* *", "BUILD", "WORKSPACE"]),
    imports = ["{pkg}"],
    deps = {dependencies},
    visibility = ["//visibility:public"],
)
"""

    build_content = """
load("//:defs.bzl", "download_wheel")
load("//:defs.bzl", "noop")
load("//:defs.bzl", "pip_install")
load("@bazel_skylib//lib:selects.bzl", "selects")

"""
    for platform in SUPPORTED_PLATFORMS:
        system, machine = platform.split("!")

        # Bazel uses windows as a platform specifier not win32
        if system == "win32":
            system = "windows"
        if system == "darwin":
            system = "macos"
        build_content += """
selects.config_setting_group(
    name = "{platform}",
    match_all = ["@platforms//os:{system}", "@platforms//cpu:{machine}"],
)
""".format(platform = platform, system = system, machine = machine)

    install_tags = ["\"{}\"".format(tag) for tag in repository_ctx.attr.tags]
    download_tags = install_tags + ["\"requires-network\""]

    for package in packages:
        # Bazel's built-in json decoder removes string escapes, so we need to
        # make sure that " characters are replaced with ' if they're wrapped
        # in quotes in the template
        if package.marker:
            marker = package.marker.replace('"', "'")
        else:
            marker = ""
        build_content += poetry_template.format(
            name = _clean_name(package.name),
            pkg = package.pkg,
            version = package.version,
            hashes = package.hashes,
            marker = marker,
            source_url = package.source_url or "",
            install_tags = ", ".join(install_tags),
            download_tags = ", ".join(download_tags),
            dependencies = [":install_%s" % _clean_name(package.name)] +
                           [":library_%s" % _clean_name(dep) for dep in package.dependencies],
        )

    excludes_template = """
noop(
    name = "library_{name}",
)
    """

    for package in excludes:
        build_content += excludes_template.format(
            name = _clean_name(package),
        )

    repository_ctx.file("BUILD", build_content)

poetry = repository_rule(
    attrs = {
        "pyproject": attr.label(
            mandatory = True,
            allow_single_file = True,
        ),
        "lockfile": attr.label(
            mandatory = True,
            allow_single_file = True,
        ),
        "excludes": attr.string_list(
            mandatory = False,
            allow_empty = True,
            default = [],
            doc = "List of packages to exclude, useful for skipping invalid dependencies",
        ),
        "python_interpreter": attr.string(
            mandatory = False,
            doc = "The command to run the Python interpreter used during repository setup",
        ),
        "python_interpreter_target_default": attr.label(
            mandatory = False,
            doc = "The target of the Python interpreter used during repository setup, if not windows or macos",
        ),
        "python_interpreter_target_win": attr.label(
            mandatory = False,
            doc = "The target of the Python interpreter used during repository setup for windows platforms",
        ),
        "python_interpreter_target_mac": attr.label(
            mandatory = False,
            doc = "The target of the Python interpreter used during repository setup for macos platforms",
        ),
        "_rules": attr.label(
            default = ":defs.bzl",
        ),
        "_wheel_wrapper": attr.label(
            default = ":wheel_wrapper.py",
        ),
        "_script": attr.label(
            executable = True,
            default = "//tools:remarshal.par",
            cfg = "exec",
        ),
    },
    implementation = _impl,
    local = False,
)
