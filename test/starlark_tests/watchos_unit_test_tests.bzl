# Copyright 2019 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""watchos_unit_test Starlark tests."""

load(
    ":common.bzl",
    "common",
)
load(
    "//test/starlark_tests/rules:analysis_output_group_info_files_test.bzl",
    "analysis_output_group_info_files_test",
)
load(
    "//test/starlark_tests/rules:apple_dsym_bundle_info_test.bzl",
    "apple_dsym_bundle_info_test",
)
load(
    "//test/starlark_tests/rules:apple_verification_test.bzl",
    "apple_verification_test",
)
load(
    "//test/starlark_tests/rules:infoplist_contents_test.bzl",
    "infoplist_contents_test",
)

def watchos_unit_test_test_suite(name):
    """Test suite for watchos_unit_test.

    Args:
      name: the base name to be used in things created by this macro
    """
    apple_verification_test(
        name = "{}_codesign_test".format(name),
        build_type = "simulator",
        target_under_test = "//test/starlark_tests/targets_under_test/watchos:unit_test",
        verifier_script = "verifier_scripts/codesign_verifier.sh",
        tags = [name],
    )

    analysis_output_group_info_files_test(
        name = "{}_dsyms_output_group_files_test".format(name),
        target_under_test = "//test/starlark_tests/targets_under_test/watchos:unit_test",
        output_group_name = "dsyms",
        expected_outputs = [
            "unit_test.__internal__.__test_bundle_dsyms/unit_test.xctest.dSYM/Contents/Info.plist",
            "unit_test.__internal__.__test_bundle_dsyms/unit_test.xctest.dSYM/Contents/Resources/DWARF/unit_test",
        ],
        tags = [name],
    )
    apple_dsym_bundle_info_test(
        name = "{}_apple_dsym_bundle_info_test".format(name),
        target_under_test = "//test/starlark_tests/targets_under_test/watchos:unit_test",
        expected_direct_dsyms = ["dSYMs/unit_test.__internal__.__test_bundle_dsyms/unit_test.xctest.dSYM"],
        expected_transitive_dsyms = ["dSYMs/unit_test.__internal__.__test_bundle_dsyms/unit_test.xctest.dSYM"],
        tags = [name],
    )

    infoplist_contents_test(
        name = "{}_plist_test".format(name),
        target_under_test = "//test/starlark_tests/targets_under_test/watchos:unit_test",
        expected_values = {
            "BuildMachineOSBuild": "*",
            "CFBundleExecutable": "unit_test",
            "CFBundleIdentifier": "com.bazelbuild.rulesapple.Tests",
            "CFBundleName": "unit_test",
            "CFBundlePackageType": "BNDL",
            "CFBundleSupportedPlatforms:0": "Watch*",
            "DTCompiler": "com.apple.compilers.llvm.clang.1_0",
            "DTPlatformBuild": "*",
            "DTPlatformName": "watchsimulator",
            "DTPlatformVersion": "*",
            "DTSDKBuild": "*",
            "DTSDKName": "watchsimulator*",
            "DTXcode": "*",
            "DTXcodeBuild": "*",
            "MinimumOSVersion": common.min_os_watchos.test_runner_support,
            "UIDeviceFamily:0": "4",
        },
        tags = [name],
    )

    native.test_suite(
        name = name,
        tags = [name],
    )
