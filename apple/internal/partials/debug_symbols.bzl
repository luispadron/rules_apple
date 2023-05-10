# Copyright 2018 The Bazel Authors. All rights reserved.
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

"""Partial implementation for debug symbol file processing."""

load(
    "@build_bazel_apple_support//lib:apple_support.bzl",
    "apple_support",
)
load(
    "@build_bazel_rules_apple//apple/internal/providers:apple_debug_info.bzl",
    "AppleDebugInfo",
)
load(
    "@build_bazel_rules_apple//apple/internal/utils:defines.bzl",
    "defines",
)
load(
    "@build_bazel_rules_apple//apple:providers.bzl",
    "AppleBundleVersionInfo",
    "AppleDsymBundleInfo",
)
load(
    "@bazel_skylib//lib:partial.bzl",
    "partial",
)
load(
    "@bazel_skylib//lib:shell.bzl",
    "shell",
)

visibility("//apple/...")

def _declare_linkmap(
        *,
        actions,
        arch,
        debug_output_filename,
        linkmap):
    """Declares a linkmap for this binary.

    Args:
      actions: The actions provider from `ctx.actions`.
      arch: The architecture specified for this particular debug output.
      debug_output_filename: The base file name to use for this debug output, which will be followed
        by the architecture with an underscore to make this linkmap's file name.
      linkmap: The linkmap that was generated by the linking action.

    Returns:
      A linkmap file for the given architecture.
    """
    output_linkmap = actions.declare_file(
        "%s_%s.linkmap" % (debug_output_filename, arch),
    )
    actions.symlink(target_file = linkmap, output = output_linkmap)
    return output_linkmap

def _collect_linkmaps(
        *,
        actions,
        debug_output_filename,
        linkmaps = {}):
    """Collects the available linkmaps from the binary.

    Args:
      actions: The actions provider from `ctx.actions`.
      debug_output_filename: The base file name to use for this debug output, which will be followed
        by each architecture with an underscore to make each linkmap's file name.
      linkmaps: A mapping of architectures to Files representing linkmaps for each architecture.

    Returns:
      A list of linkmap files, one per linked architecture.
    """
    outputs = []

    if linkmaps:
        for arch, linkmap in linkmaps.items():
            outputs.append(_declare_linkmap(
                actions = actions,
                arch = arch,
                debug_output_filename = debug_output_filename,
                linkmap = linkmap,
            ))

    return outputs

def _copy_dsyms_into_declared_bundle(
        *,
        actions,
        debug_output_filename,
        dsym_bundle_name,
        found_binaries_by_arch):
    """Declares the dSYM binary file and copies it into the preferred .dSYM bundle location.

    Args:
      actions: The actions provider from `ctx.actions`.
      debug_output_filename: The base file name to use for this debug output, which will be followed
        by the architecture with an underscore to make the dSYM binary file name or with the bundle
        extension following it for the dSYM bundle file name.
      dsym_bundle_name: The full name of the dSYM bundle, including its extension.
      found_binaries_by_arch: A mapping of architectures to Files representing dsym binary outputs
        for each architecture.

    Returns:
      A list of Files representing the copied dSYM binary which is located in the preferred .dSYM
      bundle locations.
    """
    output_binaries = []

    for arch, dsym_binary in found_binaries_by_arch.items():
        output_relpath = "Contents/Resources/DWARF/%s_%s" % (
            debug_output_filename,
            arch,
        )

        output_binary = actions.declare_file(
            "%s/%s" % (
                dsym_bundle_name,
                output_relpath,
            ),
        )

        # cp instead of symlink here because a dSYM with a symlink to the DWARF data will not be
        # recognized by spotlight which is key for lldb on mac to find a dSYM for a binary.
        # https://lldb.llvm.org/use/symbols.html
        actions.run_shell(
            inputs = [dsym_binary],
            outputs = [output_binary],
            progress_message = "Copy DWARF into dSYM `%s`" % dsym_binary.short_path,
            command = "cp -p '%s' '%s'" % (dsym_binary.path, output_binary.path),
        )

        output_binaries.append(output_binary)

    return output_binaries

def _lipo_command_for_dsyms(
        *,
        debug_output_filename,
        found_binaries_by_arch):
    """Returns a shell command to invoke lipo against all provided dSYMs for a given bundle.

    Args:
      debug_output_filename: The base file name to use for this debug output, which will be followed
        by the architecture with an underscore to make the dSYM binary file name or with the bundle
        extension following it for the dSYM bundle file name.
      found_binaries_by_arch: A mapping of architectures to Files representing dsym binary outputs
        for each architecture.

    Returns:
      A String representing the shell command to invoke lipo, referencing an OUTPUT_DIR shell
      variable that is expected to represent the dSYM bundle root.
    """
    found_binary_paths = []

    for dsym_binary in found_binaries_by_arch.values():
        found_binary_paths.append(dsym_binary.path)

    lipo_command = (
        "/usr/bin/lipo " +
        "-create {found_binary_inputs} " +
        "-output ${{OUTPUT_DIR}}/Contents/Resources/DWARF/{debug_output_filename}"
    ).format(
        found_binary_inputs = " ".join([shell.quote(path) for path in found_binary_paths]),
        debug_output_filename = debug_output_filename,
    )

    return lipo_command

def _bundle_dsym_files(
        *,
        actions,
        bundle_extension = "",
        debug_output_filename,
        dsym_binaries = {},
        dsym_info_plist_template,
        platform_prerequisites,
        version):
    """Recreates the .dSYM bundle from the AppleDebugOutputs provider and dSYM binaries.

    The generated bundle will have the same name as the bundle being built (including its
    extension), but with the ".dSYM" extension appended to it.

    If the target being built does not have a binary or if the build it not generating debug
    symbols (`--apple_generate_dsym` is not provided), then this function is a no-op that returns
    an empty list.

    Args:
      actions: The actions provider from `ctx.actions`.
      bundle_extension: The extension for the bundle.
      debug_output_filename: The base file name to use for this debug output, which will be followed
        by each architecture with an underscore to make each dSYM binary file name or with the
        bundle extension following it for the dSYM bundle file name.
      dsym_binaries: A mapping of architectures to Files representing dSYM binary outputs for each
        architecture.
      dsym_info_plist_template: File referencing a plist template for dSYM bundles.
      platform_prerequisites: Struct containing information on the platform being targeted.
      version: A label referencing AppleBundleVersionInfo, if provided by the rule.

    Returns:
      A tuple where the first argument is a list of files that comprise the .dSYM bundle, which
      should be returned as additional outputs from the target, and the second argument is a tree
      artifact representation of a .dSYM bundle with the binaries lipoed together as one binary.
    """
    dsym_bundle_name_with_extension = debug_output_filename + bundle_extension
    dsym_bundle_name = dsym_bundle_name_with_extension + ".dSYM"

    output_files = []
    dsym_bundle_dir = None

    found_binaries_by_arch = {}

    if dsym_binaries:
        found_binaries_by_arch.update(dsym_binaries)

    if found_binaries_by_arch:
        output_files = _copy_dsyms_into_declared_bundle(
            actions = actions,
            debug_output_filename = debug_output_filename,
            dsym_bundle_name = dsym_bundle_name,
            found_binaries_by_arch = found_binaries_by_arch,
        )
        lipo_command = _lipo_command_for_dsyms(
            debug_output_filename = debug_output_filename,
            found_binaries_by_arch = found_binaries_by_arch,
        )

        # If we found any outputs, create the Info.plist for the bundle as well; otherwise, we just
        # return the empty list. The plist generated by dsymutil only varies based on the bundle
        # name, so we regenerate it here rather than propagate the other one from the apple_binary.
        # (See https://github.com/llvm-mirror/llvm/blob/master/tools/dsymutil/dsymutil.cpp)
        dsym_plist = actions.declare_file(
            "%s/Contents/Info.plist" % dsym_bundle_name,
        )
        output_files.append(dsym_plist)
        dsym_relpath = "Contents/Info.plist"

        build_version = "1"
        short_version_string = "1.0"
        if version != None and AppleBundleVersionInfo in version:
            version_info = version[AppleBundleVersionInfo]
            build_version = version_info.build_version
            short_version_string = version_info.short_version_string

        actions.expand_template(
            output = dsym_plist,
            template = dsym_info_plist_template,
            substitutions = {
                "%bundle_name_with_extension%": dsym_bundle_name_with_extension,
                "%bundle_short_version_string%": short_version_string,
                "%bundle_version_string%": build_version,
            },
        )

        plist_command = ("cp {dsym_plist_path} ${{OUTPUT_DIR}}/{dsym_relpath_path}").format(
            dsym_plist_path = dsym_plist.path,
            dsym_relpath_path = dsym_relpath,
        )

        # Put the tree artifact dSYMs in a subdirectory to avoid conflicts with the legacy dSYMs
        # provided through existing APIs such as --output_groups=+dsyms.
        dsym_bundle_dir = actions.declare_directory("dSYMs/" + dsym_bundle_name)

        apple_support.run_shell(
            actions = actions,
            apple_fragment = platform_prerequisites.apple_fragment,
            inputs = [dsym_plist] + found_binaries_by_arch.values(),
            outputs = [dsym_bundle_dir],
            command = ("mkdir -p ${OUTPUT_DIR}/Contents/Resources/DWARF && " + lipo_command +
                       " && " + plist_command),
            env = {
                "OUTPUT_DIR": dsym_bundle_dir.path,
            },
            mnemonic = "DSYMBundleCopy",
            xcode_config = platform_prerequisites.xcode_version_config,
        )

    return output_files, dsym_bundle_dir

def _debug_symbols_partial_impl(
        *,
        actions,
        bundle_extension,
        bundle_name,
        debug_dependencies = [],
        debug_discriminator = None,
        dsym_binaries = {},
        dsym_info_plist_template,
        linkmaps = {},
        platform_prerequisites,
        version):
    """Implementation for the debug symbols processing partial."""
    deps_dsym_bundle_providers = [
        x[AppleDsymBundleInfo]
        for x in debug_dependencies
        if AppleDsymBundleInfo in x
    ]
    deps_debug_info_providers = [
        x[AppleDebugInfo]
        for x in debug_dependencies
        if AppleDebugInfo in x
    ]

    debug_output_filename = bundle_name
    if debug_discriminator:
        debug_output_filename += "_" + debug_discriminator

    direct_dsym_bundles = []
    transitive_dsym_bundles = [x.transitive_dsyms for x in deps_dsym_bundle_providers]

    direct_dsyms = []
    transitive_dsyms = [x.dsyms for x in deps_debug_info_providers]

    direct_linkmaps = []
    transitive_linkmaps = [x.linkmaps for x in deps_debug_info_providers]

    output_providers = []

    if platform_prerequisites.cpp_fragment:
        if platform_prerequisites.cpp_fragment.apple_generate_dsym:
            dsym_files, dsym_bundle_dir = _bundle_dsym_files(
                actions = actions,
                bundle_extension = bundle_extension,
                debug_output_filename = debug_output_filename,
                dsym_binaries = dsym_binaries,
                dsym_info_plist_template = dsym_info_plist_template,
                platform_prerequisites = platform_prerequisites,
                version = version,
            )
            if dsym_bundle_dir:
                direct_dsym_bundles.append(dsym_bundle_dir)
            direct_dsyms.extend(dsym_files)

        if platform_prerequisites.cpp_fragment.objc_generate_linkmap:
            linkmaps = _collect_linkmaps(
                actions = actions,
                debug_output_filename = debug_output_filename,
                linkmaps = linkmaps,
            )
            direct_linkmaps.extend(linkmaps)

    # Only output dependency debug files if requested.
    propagate_embedded_extra_outputs = defines.bool_value(
        config_vars = platform_prerequisites.config_vars,
        define_name = "apple.propagate_embedded_extra_outputs",
        default = False,
    )

    # Output the tree artifact dSYMs as the default outputs if requested.
    tree_artifact_dsym_files = defines.bool_value(
        config_vars = platform_prerequisites.config_vars,
        define_name = "apple.tree_artifact_dsym_files",
        default = False,
    )

    dsyms_group = depset(direct_dsyms, transitive = transitive_dsyms)
    linkmaps_group = depset(direct_linkmaps, transitive = transitive_linkmaps)

    if tree_artifact_dsym_files:
        all_output_dsyms = depset(direct_dsym_bundles, transitive = transitive_dsym_bundles)
        direct_output_dsyms = direct_dsym_bundles
    else:
        all_output_dsyms = dsyms_group
        direct_output_dsyms = direct_dsyms

    if propagate_embedded_extra_outputs:
        output_files = depset(transitive = [all_output_dsyms, linkmaps_group])
    else:
        output_files = depset(direct_output_dsyms + direct_linkmaps)

    output_providers.extend([
        AppleDsymBundleInfo(
            direct_dsyms = direct_dsym_bundles,
            transitive_dsyms = depset(direct_dsym_bundles, transitive = transitive_dsym_bundles),
        ),
        AppleDebugInfo(
            dsyms = dsyms_group,
            linkmaps = linkmaps_group,
        ),
    ])

    return struct(
        output_files = output_files,
        output_groups = {
            "dsyms": all_output_dsyms,
            "linkmaps": linkmaps_group,
        },
        providers = output_providers,
    )

def debug_symbols_partial(
        *,
        actions,
        bundle_extension,
        bundle_name,
        debug_dependencies = [],
        debug_discriminator = None,
        dsym_binaries = {},
        dsym_info_plist_template,
        linkmaps = {},
        platform_prerequisites,
        version):
    """Constructor for the debug symbols processing partial.

    This partial collects all of the transitive debug files information. The output of this partial
    are the debug output files for the target being processed _plus_ all of the dependencies debug
    symbol files. This includes dSYM bundles and linkmaps. With this, for example, by building an
    ios_application target with --apple_generate_dsym, this partial will return the dSYM bundle of
    the ios_application itself plus the dSYM bundles of any ios_framework and ios_extension
    dependencies there may be, which will force bazel to present these files in the output files
    section of a successful build.

    Args:
      actions: The actions provider from `ctx.actions`.
      bundle_extension: The extension for the bundle.
      bundle_name: The name of the output bundle.
      debug_dependencies: List of targets from which to collect the transitive dependency debug
        information to propagate them upstream.
      debug_discriminator: A suffix to distinguish between different debug output files, or `None`.
      dsym_binaries: A mapping of architectures to Files representing dsym binary outputs for each
        architecture.
      dsym_info_plist_template: File referencing a plist template for dSYM bundles.
      linkmaps: A mapping of architectures to Files representing linkmaps for each architecture.
      platform_prerequisites: Struct containing information on the platform being targeted.
      version: A label referencing AppleBundleVersionInfo, if provided by the rule.

    Returns:
      A partial that returns the debug output files, if any were requested.
    """
    return partial.make(
        _debug_symbols_partial_impl,
        actions = actions,
        bundle_extension = bundle_extension,
        bundle_name = bundle_name,
        debug_dependencies = debug_dependencies,
        debug_discriminator = debug_discriminator,
        dsym_binaries = dsym_binaries,
        dsym_info_plist_template = dsym_info_plist_template,
        linkmaps = linkmaps,
        platform_prerequisites = platform_prerequisites,
        version = version,
    )
