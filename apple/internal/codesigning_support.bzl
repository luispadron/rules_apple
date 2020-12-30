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

"""Actions related to codesigning."""

load(
    "@build_bazel_rules_apple//apple/internal/utils:defines.bzl",
    "defines",
)
load(
    "@build_bazel_rules_apple//apple/internal/utils:legacy_actions.bzl",
    "legacy_actions",
)
load(
    "@build_bazel_rules_apple//apple/internal:intermediates.bzl",
    "intermediates",
)
load(
    "@build_bazel_rules_apple//apple/internal:rule_support.bzl",
    "rule_support",
)
load(
    "@bazel_skylib//lib:paths.bzl",
    "paths",
)
load(
    "@bazel_skylib//lib:shell.bzl",
    "shell",
)

def _double_quote(raw_string):
    """Add double quotes around the string and preserve existing quote characters.

    Args:
      raw_string: A string that might have shell-syntaxed environment variables.

    Returns:
      The string with double quotes.
    """
    return "\"" + raw_string.replace("\"", "\\\"") + "\""

def _no_op(x):
    """Helper that does not nothing be return the result."""
    return x

def _codesign_args_for_path(
        *,
        entitlements_file,
        path_to_sign,
        platform_prerequisites,
        provisioning_profile,
        shell_quote = True):
    """Returns a command line for the codesigning tool wrapper script.

    Args:
      entitlements_file: The entitlements file to pass to codesign. May be `None`
          for non-app binaries (e.g. test bundles).
      path_to_sign: A struct indicating the path that should be signed and its
          optionality (see `_path_to_sign`).
      platform_prerequisites: Struct containing information on the platform being targeted.
      provisioning_profile: The provisioning profile file. May be `None`.
      shell_quote: Sanitizes the arguments to be evaluated in a shell.

    Returns:
      The codesign command invocation for the given directory as a list.
    """
    if not path_to_sign.is_directory and path_to_sign.signed_frameworks:
        fail("Internal Error: Received a list of signed frameworks as exceptions " +
             "for code signing, but path to sign is not a directory.")

    for x in path_to_sign.signed_frameworks:
        if not x.startswith(path_to_sign.path):
            fail("Internal Error: Signed framework does not have the current path " +
                 "to sign (%s) as its prefix (%s)." % (path_to_sign.path, x))

    cmd_codesigning = [
        "--codesign",
        "/usr/bin/codesign",
    ]

    is_device = platform_prerequisites.platform.is_device

    # Add quotes for sanitizing inputs when they're invoked directly from a shell script, for
    # instance when using this string to assemble the output of codesigning_command.
    maybe_quote = shell.quote if shell_quote else _no_op
    maybe_double_quote = _double_quote if shell_quote else _no_op

    # First, try to use the identity passed on the command line, if any. If it's a simulator build,
    # use an ad hoc identity.
    identity = platform_prerequisites.objc_fragment.signing_certificate_name if is_device else "-"
    if not identity:
        if provisioning_profile:
            cmd_codesigning.extend([
                "--mobileprovision",
                maybe_quote(provisioning_profile.path),
            ])

        else:
            identity = "-"

    if identity:
        cmd_codesigning.extend([
            "--identity",
            maybe_quote(identity),
        ])

    if is_device:
        if path_to_sign.use_entitlements and entitlements_file:
            cmd_codesigning.extend([
                "--entitlements",
                maybe_quote(entitlements_file.path),
            ])
        cmd_codesigning.append("--force")
    else:
        cmd_codesigning.extend([
            "--force",
            "--disable_timestamp",
        ])

    if path_to_sign.is_directory:
        cmd_codesigning.append("--directory_to_sign")
    else:
        cmd_codesigning.append("--target_to_sign")

    # Because the path does include environment variables which need to be expanded, path has to be
    # quoted using double quotes, this means that path can't be quoted using shell.quote.
    cmd_codesigning.append(maybe_double_quote(path_to_sign.path))

    if path_to_sign.signed_frameworks:
        for signed_framework in path_to_sign.signed_frameworks:
            # Signed frameworks must also be double quoted, as they too have an environment
            # variable to be expanded.
            cmd_codesigning.extend([
                "--signed_path",
                maybe_double_quote(signed_framework),
            ])

    return cmd_codesigning

def _path_to_sign(*, path, is_directory = False, signed_frameworks = [], use_entitlements = True):
    """Returns a "path to sign" value to be passed to `_signing_command_lines`.

    Args:
      path: The path to sign, relative to wherever the code signing command lines
          are being executed.
      is_directory: If `True`, the path is a directory and not a bundle, indicating
          that the contents of each item in the directory should be code signed
          except for the invisible files prefixed with a period.
      signed_frameworks: If provided, a list of frameworks that have already been signed.
      use_entitlements: If provided, indicates if the entitlements on the bundling
          target should be used for signing this path (useful to disabled the use
          when signing frameworks within an iOS app).

    Returns:
      A `struct` that can be passed to `_signing_command_lines`.
    """
    return struct(
        path = path,
        is_directory = is_directory,
        signed_frameworks = signed_frameworks,
        use_entitlements = use_entitlements,
    )

def _validate_provisioning_profile(
        *,
        rule_descriptor,
        platform_prerequisites,
        provisioning_profile):
    # Verify that a provisioning profile was provided for device builds on
    # platforms that require it.
    is_device = platform_prerequisites.platform.is_device
    if (is_device and
        rule_descriptor.requires_signing_for_device and
        not provisioning_profile):
        fail("The provisioning_profile attribute must be set for device " +
             "builds on this platform (%s)." %
             platform_prerequisites.platform_type)

def _signing_command_lines(
        *,
        codesigningtool,
        entitlements_file,
        paths_to_sign,
        platform_prerequisites,
        provisioning_profile):
    """Returns a multi-line string with codesign invocations for the bundle.

    For any signing identity other than ad hoc, the identity is verified as being
    valid in the keychain and an error will be emitted if the identity cannot be
    used for signing for any reason.

    Args:
      codesigningtool: The `File` representing the code signing tool.
      entitlements_file: The entitlements file to pass to codesign.
      paths_to_sign: A list of values returned from `path_to_sign` that indicate
          paths that should be code-signed.
      platform_prerequisites: Struct containing information on the platform being targeted.
      provisioning_profile: The provisioning profile file. May be `None`.

    Returns:
      A multi-line string with codesign invocations for the bundle.
    """
    commands = []

    # Use of the entitlements file is not recommended for the signing of frameworks. As long as
    # this remains the case, we do have to split the "paths to sign" between multiple invocations
    # of codesign.
    for path_to_sign in paths_to_sign:
        codesign_command = [codesigningtool.path]
        codesign_command.extend(_codesign_args_for_path(
            entitlements_file = entitlements_file,
            path_to_sign = path_to_sign,
            platform_prerequisites = platform_prerequisites,
            provisioning_profile = provisioning_profile,
        ))
        commands.append(" ".join(codesign_command))
    return "\n".join(commands)

def _should_sign_simulator_bundles(
        *,
        config_vars,
        rule_descriptor):
    """Check if a main bundle should be codesigned.

    The Frameworks/* bundles should *always* be signed, this is just for
    the other bundles.

    Args:

    Returns:
      True/False for if the bundle should be signed.

    """
    if not rule_descriptor.skip_simulator_signing_allowed:
        return True

    # Default is to sign.
    return defines.bool_value(
        config_vars = config_vars,
        define_name = "apple.codesign_simulator_bundles",
        default = True,
    )

def _should_sign_bundles(*, provisioning_profile, rule_descriptor):
    should_sign_bundles = True

    codesigning_exceptions = rule_descriptor.codesigning_exceptions
    if (codesigning_exceptions ==
        rule_support.codesigning_exceptions.sign_with_provisioning_profile):
        # If the rule doesn't have a provisioning profile, do not sign the binary or its
        # frameworks.
        if not provisioning_profile:
            should_sign_bundles = False
    elif codesigning_exceptions == rule_support.codesigning_exceptions.skip_signing:
        should_sign_bundles = False
    elif codesigning_exceptions != rule_support.codesigning_exceptions.none:
        fail("Internal Error: Encountered unsupported state for codesigning_exceptions.")

    return should_sign_bundles

def _codesigning_args(
        *,
        entitlements,
        full_archive_path,
        is_framework = False,
        platform_prerequisites,
        provisioning_profile,
        rule_descriptor):
    """Returns a set of codesigning arguments to be passed to the codesigning tool.

    Args:
        entitlements: The entitlements file to sign with. Can be None.
        full_archive_path: The full path to the codesigning target.
        is_framework: If the target is a framework. False by default.
        platform_prerequisites: Struct containing information on the platform being targeted.
        provisioning_profile: File for the provisioning profile.
        rule_descriptor: A rule descriptor for platform and product types from the rule context.

    Returns:
        A list containing the arguments to pass to the codesigning tool.
    """
    should_sign_bundles = _should_sign_bundles(
        provisioning_profile = provisioning_profile,
        rule_descriptor = rule_descriptor,
    )
    if not should_sign_bundles:
        return []

    is_device = platform_prerequisites.platform.is_device
    should_sign_sim_bundles = _should_sign_simulator_bundles(
        config_vars = platform_prerequisites.config_vars,
        rule_descriptor = rule_descriptor,
    )
    if not is_framework and not is_device and not should_sign_sim_bundles:
        return []

    _validate_provisioning_profile(
        platform_prerequisites = platform_prerequisites,
        provisioning_profile = provisioning_profile,
        rule_descriptor = rule_descriptor,
    )

    return _codesign_args_for_path(
        entitlements_file = entitlements,
        path_to_sign = _path_to_sign(path = full_archive_path),
        platform_prerequisites = platform_prerequisites,
        provisioning_profile = provisioning_profile,
        shell_quote = False,
    )

def _codesigning_command(
        *,
        bundle_path = "",
        codesigningtool,
        entitlements,
        frameworks_path,
        platform_prerequisites,
        provisioning_profile,
        rule_descriptor,
        signed_frameworks):
    """Returns a codesigning command that includes framework embedded bundles.

    Args:
        bundle_path: The location of the bundle, relative to the archive.
        codesigningtool: The `File` representing the code signing tool.
        entitlements: The entitlements file to sign with. Can be None.
        frameworks_path: The location of the Frameworks directory, relative to the archive.
        platform_prerequisites: Struct containing information on the platform being targeted.
        provisioning_profile: File for the provisioning profile.
        rule_descriptor: A rule descriptor for platform and product types from the rule context.
        signed_frameworks: A depset containing each framework that has already been signed.

    Returns:
        A string containing the codesigning commands.
    """
    should_sign_bundles = _should_sign_bundles(
        provisioning_profile = provisioning_profile,
        rule_descriptor = rule_descriptor,
    )
    if not should_sign_bundles:
        return ""

    _validate_provisioning_profile(
        platform_prerequisites = platform_prerequisites,
        provisioning_profile = provisioning_profile,
        rule_descriptor = rule_descriptor,
    )
    paths_to_sign = []

    # The command returned by this function is executed as part of a bundling shell script.
    # Each directory to be signed must be prefixed by $WORK_DIR, which is the variable in that
    # script that contains the path to the directory where the bundle is being built.
    if frameworks_path:
        framework_root = paths.join("$WORK_DIR", frameworks_path) + "/"
        full_signed_frameworks = []

        for signed_framework in signed_frameworks.to_list():
            full_signed_frameworks.append(paths.join(framework_root, signed_framework))

        paths_to_sign.append(
            _path_to_sign(
                path = framework_root,
                is_directory = True,
                signed_frameworks = full_signed_frameworks,
                use_entitlements = False,
            ),
        )
    should_sign_sim_bundles = _should_sign_simulator_bundles(
        config_vars = platform_prerequisites.config_vars,
        rule_descriptor = rule_descriptor,
    )
    if platform_prerequisites.platform.is_device or should_sign_sim_bundles:
        path_to_sign = paths.join("$WORK_DIR", bundle_path)
        paths_to_sign.append(
            _path_to_sign(path = path_to_sign),
        )
    return _signing_command_lines(
        codesigningtool = codesigningtool,
        entitlements_file = entitlements,
        paths_to_sign = paths_to_sign,
        platform_prerequisites = platform_prerequisites,
        provisioning_profile = provisioning_profile,
    )

def _post_process_and_sign_archive_action(
        *,
        actions,
        archive_codesigning_path,
        codesigningtool,
        entitlements = None,
        frameworks_path,
        input_archive,
        ipa_post_processor,
        label_name,
        output_archive,
        output_archive_root_path,
        platform_prerequisites,
        process_and_sign_template,
        provisioning_profile,
        rule_descriptor,
        signed_frameworks):
    """Post-processes and signs an archived bundle.

    Args:
      actions: The actions provider from `ctx.actions`.
      archive_codesigning_path: The codesigning path relative to the archive.
      codesigningtool: The `File` representing the code signing tool.
      entitlements: Optional file representing the entitlements to sign with.
      frameworks_path: The Frameworks path relative to the archive.
      input_archive: The `File` representing the archive containing the bundle
          that has not yet been processed or signed.
      ipa_post_processor: A file that acts as a bundle post processing tool. May be `None`.
      label_name: Name of the target being built.
      output_archive: The `File` representing the processed and signed archive.
      output_archive_root_path: The `string` path to where the processed, uncompressed archive
          should be located.
      platform_prerequisites: Struct containing information on the platform being targeted.
      process_and_sign_template: A template for a shell script to process and sign as a file.
      provisioning_profile: The provisioning profile file. May be `None`.
      rule_descriptor: A rule descriptor for platform and product types from the rule context.
      signed_frameworks: Depset containing each framework that has already been signed.
    """
    input_files = [input_archive]
    processing_tools = []

    signing_command_lines = _codesigning_command(
        bundle_path = archive_codesigning_path,
        codesigningtool = codesigningtool,
        entitlements = entitlements,
        frameworks_path = frameworks_path,
        platform_prerequisites = platform_prerequisites,
        provisioning_profile = provisioning_profile,
        rule_descriptor = rule_descriptor,
        signed_frameworks = signed_frameworks,
    )
    if signing_command_lines:
        processing_tools.append(codesigningtool)
        if entitlements:
            input_files.append(entitlements)
        if provisioning_profile:
            input_files.append(provisioning_profile)

    ipa_post_processor_path = ""
    if ipa_post_processor:
        processing_tools.append(ipa_post_processor)
        ipa_post_processor_path = ipa_post_processor.path

    # Only compress the IPA for optimized (release) builds or when requested.
    # For debug builds, zip without compression, which will speed up the build.
    config_vars = platform_prerequisites.config_vars
    compression_requested = defines.bool_value(
        config_vars = config_vars,
        define_name = "apple.compress_ipa",
        default = False,
    )
    should_compress = (config_vars["COMPILATION_MODE"] == "opt") or compression_requested

    # TODO(b/163217926): These are kept the same for the three different actions
    # that could be run to ensure anything keying off these values continues to
    # work. After some data is collected, the values likely can be revisited and
    # changed.
    mnemonic = "ProcessAndSign"
    progress_message = "Processing and signing %s" % label_name

    # If there is no work to be done, skip the processing/signing action, just
    # copy the file over.
    has_work = any([signing_command_lines, ipa_post_processor_path, should_compress])
    if not has_work:
        actions.run_shell(
            command = "cp -p '%s' '%s'" % (input_archive.path, output_archive.path),
            inputs = [input_archive],
            mnemonic = mnemonic,
            outputs = [output_archive],
            progress_message = progress_message,
        )
        return

    process_and_sign_expanded_template = intermediates.file(
        actions,
        label_name,
        "process-and-sign-%s.sh" % hash(output_archive.path),
    )
    actions.expand_template(
        template = process_and_sign_template,
        output = process_and_sign_expanded_template,
        is_executable = True,
        substitutions = {
            "%ipa_post_processor%": ipa_post_processor_path or "",
            "%output_path%": output_archive.path,
            "%should_compress%": "1" if should_compress else "",
            "%signing_command_lines%": signing_command_lines,
            "%unprocessed_archive_path%": input_archive.path,
            "%work_dir%": output_archive_root_path,
        },
    )

    # Build up some arguments for the script to allow logging to tell what work
    # is being done within the action's script.
    arguments = []
    if signing_command_lines:
        arguments.append("should_sign")
    if ipa_post_processor_path:
        arguments.append("should_process")
    if should_compress:
        arguments.append("should_compress")

    run_on_darwin = any([signing_command_lines, ipa_post_processor_path])
    if run_on_darwin:
        legacy_actions.run(
            actions = actions,
            arguments = arguments,
            executable = process_and_sign_expanded_template,
            execution_requirements = {
                # Added so that the output of this action is not cached remotely, in case multiple
                # developers sign the same artifact with different identities.
                "no-cache": "1",
                # Unsure, but may be needed for keychain access, especially for files that live in
                # $HOME.
                "no-sandbox": "1",
            },
            inputs = input_files,
            mnemonic = mnemonic,
            outputs = [output_archive],
            platform_prerequisites = platform_prerequisites,
            progress_message = progress_message,
            tools = processing_tools,
        )
    else:
        actions.run(
            arguments = arguments,
            executable = process_and_sign_expanded_template,
            inputs = input_files,
            mnemonic = mnemonic,
            outputs = [output_archive],
            progress_message = progress_message,
        )

def _sign_binary_action(
        *,
        actions,
        codesigningtool,
        input_binary,
        output_binary,
        platform_prerequisites,
        provisioning_profile,
        rule_descriptor):
    """Signs the input binary file, copying it into the given output binary file.

    Args:
      actions: The actions provider from `ctx.actions`.
      codesigningtool: The `File` representing the code signing tool.
      input_binary: The `File` representing the binary to be signed.
      output_binary: The `File` representing signed binary.
      platform_prerequisites: Struct containing information on the platform being targeted.
      provisioning_profile: The provisioning profile file. May be `None`.
      rule_descriptor: A rule descriptor for platform and product types from the rule context.
    """
    _validate_provisioning_profile(
        platform_prerequisites = platform_prerequisites,
        provisioning_profile = provisioning_profile,
        rule_descriptor = rule_descriptor,
    )

    # It's not hermetic to sign the binary that was built by the apple_binary
    # target that this rule takes as an input, so we copy it and then execute the
    # code signing commands on that copy in the same action.
    path_to_sign = _path_to_sign(path = output_binary.path)
    signing_commands = _signing_command_lines(
        codesigningtool = codesigningtool,
        entitlements_file = None,
        paths_to_sign = [path_to_sign],
        platform_prerequisites = platform_prerequisites,
        provisioning_profile = provisioning_profile,
    )

    legacy_actions.run_shell(
        actions = actions,
        command = [
            "/bin/bash",
            "-c",
            "cp {input_binary} {output_binary}".format(
                input_binary = input_binary.path,
                output_binary = output_binary.path,
            ) + "\n" + signing_commands,
        ],
        execution_requirements = {
            # Added so that the output of this action is not cached remotely, in case multiple
            # developers sign the same artifact with different identities.
            "no-cache": "1",
            # Unsure, but may be needed for keychain access, especially for files that live in
            # $HOME.
            "no-sandbox": "1",
        },
        inputs = [input_binary],
        mnemonic = "SignBinary",
        outputs = [output_binary],
        platform_prerequisites = platform_prerequisites,
        tools = [codesigningtool],
    )

codesigning_support = struct(
    codesigning_args = _codesigning_args,
    codesigning_command = _codesigning_command,
    post_process_and_sign_archive_action = _post_process_and_sign_archive_action,
    sign_binary_action = _sign_binary_action,
)
