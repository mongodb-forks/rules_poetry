load("@pypi//:requirements.bzl", "requirement")

py_binary(
    name = "remarshal",
    srcs = ["remarshal.py"],
    visibility = ["//visibility:public"],
    deps = [
        requirement("PyYAML"),
        requirement("python-dateutil"),
        requirement("pytoml"),
        requirement("remarshal"),
        requirement("six"),
    ],
)

filegroup(
    name = "remarshal_zip",
    srcs = [":remarshal"],
    output_group = "python_zip_file",
)
