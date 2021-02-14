load("@rules_proto//proto:defs.bzl", "ProtoInfo")
load(
    "//internal:common.bzl",
    "copy_file",
    "descriptor_proto_path",
    "get_int_attr",
    "get_output_filename",
    "get_package_root",
    "strip_path_prefix",
)
load("//internal:providers.bzl", "ProtoCompileInfo", "ProtoLibraryAspectNodeInfo", "ProtoPluginInfo")

proto_compile_attrs = {
    # Deps and protos attrs are added per-rule, as it depends on aspect name
    "verbose": attr.int(
        doc = "The verbosity level. Supported values and results are 1: *show command*, 2: *show command and sandbox after running protoc*, 3: *show command and sandbox before and after running protoc*, 4. *show env, command, expected outputs and sandbox before and after running protoc*",
    ),
    "verbose_string": attr.string(
        doc = "String version of the verbose string, used for aspect",
        default = "0",
    ),
    "prefix_path": attr.string(
        doc = "Path to prefix to the generated files in the output directory. Cannot be set when merge_directories == False",
    ),
    "merge_directories": attr.bool(
        doc = "If true, all generated files are merged into a single directory with the name of current label and these new files returned as the outputs. If false, the original generated files are returned across multiple roots",
        default = True,
    ),
}

proto_compile_aspect_attrs = {
    "verbose_string": attr.string(
        doc = "String version of the verbose string, used for aspect",
        values = ["", "None", "0", "1", "2", "3", "4"],
        default = "0",
    ),
}

def common_compile(ctx, proto_infos):
    ###
    ### Setup common state
    ###

    # Load attrs
    verbose = get_int_attr(ctx.attr, "verbose_string")  # Integer verbosity level
    plugins = [plugin[ProtoPluginInfo] for plugin in ctx.attr._plugins]

    # Load toolchain
    protoc_toolchain_info = ctx.toolchains[str(Label("//protobuf:toolchain_type"))]
    protoc = protoc_toolchain_info.protoc_executable
    fixer = protoc_toolchain_info.fixer_executable

    # The directory where the outputs will be generated, relative to the package. This contains the aspect _prefix attr
    # to disambiguate different aspects that may share the same plugins and would otherwise try to touch the same file.
    # The same is true for the verbose_string attr.
    rel_output_root = "{}/{}_verb{}".format(ctx.label.name, ctx.attr._prefix, verbose)

    # The full path to the output root, relative to the workspace
    output_root = get_package_root(ctx) + "/" + rel_output_root

    # The lists of generated files and directories that we expect to be produced.
    output_files = []
    output_dirs = []

    ###
    ### Setup plugins
    ###

    # Each plugin is isolated to its own execution of protoc, as plugins may have differing exclusions that cannot be
    # expressed in a single protoc execution for all plugins.

    for plugin in plugins:
        ###
        ### Fetch plugin tool and runfiles
        ###

        # Files required for running the plugin
        plugin_runfiles = []

        # Plugin input manifests
        plugin_input_manifests = None

        # Get plugin name
        plugin_name = plugin.name
        if plugin.protoc_plugin_name:
            plugin_name = plugin.protoc_plugin_name

        # Add plugin executable if not a built-in plugin
        plugin_tool = None
        if plugin.tool_executable:
            plugin_tool = plugin.tool_executable

        # Add plugin runfiles if plugin has a tool
        if plugin.tool:
            plugin_runfiles, plugin_input_manifests = ctx.resolve_tools(tools = [plugin.tool])
            plugin_runfiles = plugin_runfiles.to_list()

        # Add extra plugin data files to runfiles
        plugin_runfiles += plugin.data

        # Check plugin outputs
        if plugin.output_directory and (plugin.out or plugin.outputs or plugin.empty_template):
            fail("Proto plugin {} cannot use output_directory in conjunction with outputs, out or empty_template".format(plugin.name))

        ###
        ### Gather proto files and filter by exclusions
        ###

        protos = []  # The filtered set of .proto files to compile
        plugin_outputs = []
        proto_paths = []  # The paths passed to protoc
        for proto_info in proto_infos:
            for proto in proto_info.direct_sources:
                # Check for exclusion
                if any([
                    proto.dirname.endswith(exclusion) or proto.path.endswith(exclusion)
                    for exclusion in plugin.exclusions
                ]) or proto in protos:
                    # When using import_prefix, the ProtoInfo.direct_sources list appears to contain duplicate records,
                    # the final check 'proto in protos' removes these. See https://github.com/bazelbuild/bazel/issues/9127
                    continue

                # Proto not excluded
                protos.append(proto)

                # Add per-proto outputs
                for pattern in plugin.outputs:
                    plugin_outputs.append(ctx.actions.declare_file("{}/{}".format(
                        rel_output_root,
                        get_output_filename(proto, pattern, proto_info),
                    )))

                # Get proto path for protoc
                proto_paths.append(descriptor_proto_path(proto, proto_info))

        # Skip plugin if all proto files have now been excluded
        if len(protos) == 0:
            if verbose > 2:
                print(
                    'Skipping plugin "{}" for "{}" as all proto files have been excluded'.format(plugin.name, ctx.label),
                )
            continue

        # Append current plugin outputs to global outputs before looking at per-plugin outputs; these are manually added
        # globally as there may be srcjar outputs.
        output_files.extend(plugin_outputs)

        ###
        ### Declare per-plugin outputs
        ###

        # Some protoc plugins generate a set of output files (like python) while others generate a single 'archive' file
        # that contains the individual outputs (like java). Jar outputs are gathered as a special case as we need to
        # post-process them to have a 'srcjar' extension (java_library rules don't accept source jars with a 'jar'
        # extension).

        out_file = None
        if plugin.out:
            # Define out file
            out_file = ctx.actions.declare_file("{}/{}".format(
                rel_output_root,
                plugin.out.replace("{name}", ctx.label.name),
            ))
            plugin_outputs.append(out_file)

            if not out_file.path.endswith(".jar"):
                # Add output direct to global outputs
                output_files.append(out_file)
            else:
                # Create .srcjar from .jar for global outputs
                output_files.append(copy_file(
                    ctx,
                    out_file,
                    "{}.srcjar".format(out_file.basename.rpartition(".")[0]),
                    sibling = out_file,
                ))

        ###
        ### Declare plugin output directory if required
        ###

        # Some plugins outputs a structure that cannot be predicted from the input file paths alone. For these plugins,
        # we simply declare the directory.

        if plugin.output_directory:
            out_file = ctx.actions.declare_directory(rel_output_root + "/" + "_plugin_" + plugin.name)
            plugin_outputs.append(out_file)
            output_dirs.append(out_file)

        ###
        ### Build command
        ###

        # Determine the outputs expected by protoc.
        # When plugin.empty_template is not set, protoc will output directly to the final targets. When set, we will
        # direct the plugin outputs to a temporary folder, then use the fixer executable to write to the final targets.
        if plugin.empty_template:
            # Create path list for fixer
            fixer_paths_file = ctx.actions.declare_file(rel_output_root + "/" + "_plugin_ef_" + plugin.name + ".txt")
            ctx.actions.write(fixer_paths_file, "\n".join([
                file.path.partition(output_root + "/")[2]
                for file in plugin_outputs
            ]))

            # Create output directory for protoc to write into
            fixer_dir = ctx.actions.declare_directory(rel_output_root + "/" + "_plugin_ef_" + plugin.name)
            out_arg = fixer_dir.path
            plugin_protoc_outputs = [fixer_dir]

            # Apply fixer
            ctx.actions.run(
                inputs = [fixer_paths_file, fixer_dir, plugin.empty_template],
                outputs = plugin_outputs,
                arguments = [
                    fixer_paths_file.path,
                    plugin.empty_template.path,
                    fixer_dir.path,
                    output_root,
                ],
                progress_message = "Applying fixer for {} plugin on target {}".format(plugin.name, ctx.label),
                executable = fixer,
            )

        else:
            # No fixer, protoc writes files directly
            out_arg = out_file.path if out_file else output_root
            plugin_protoc_outputs = plugin_outputs

        # Argument list for protoc execution
        args = ctx.actions.args()

        # Add transitive descriptors
        pathsep = ctx.configuration.host_path_separator
        args.add("--descriptor_set_in={}".format(pathsep.join(
            [f.path for f in proto_info.transitive_descriptor_sets.to_list() for proto_info in proto_infos],
        )))

        # Add --plugin if not a built-in plugin
        if plugin_tool:
            # If Windows, mangle the path. It's done a bit awkwardly with
            # `host_path_seprator` as there is no simple way to figure out what's
            # the current OS.
            plugin_tool_path = None
            if ctx.configuration.host_path_separator == ";":
                plugin_tool_path = plugin_tool.path.replace("/", "\\")
            else:
                plugin_tool_path = plugin_tool.path

            args.add("--plugin=protoc-gen-{}={}".format(plugin_name, plugin_tool_path))

        # Add plugin --*_out/--*_opt args
        if plugin.options:
            opts_str = ",".join(
                [option.replace("{name}", ctx.label.name) for option in plugin.options],
            )
            if plugin.separate_options_flag:
                args.add("--{}_opt={}".format(plugin_name, opts_str))
            else:
                out_arg = "{}:{}".format(opts_str, out_arg)
        args.add("--{}_out={}".format(plugin_name, out_arg))

        # Add any extra protoc args that the plugin has
        if plugin.extra_protoc_args:
            args.add_all(plugin.extra_protoc_args)

        # Add source proto files as descriptor paths
        for proto_path in proto_paths:
            args.add(proto_path)

        ###
        ### Specify protoc action
        ###

        mnemonic = "ProtoCompile"
        command = ("mkdir -p '{}' && ".format(output_root)) + protoc.path + " $@"  # $@ is replaced with args list
        inputs = [
            descriptor
            for descriptor in proto_info.transitive_descriptor_sets.to_list()
            for proto_info in proto_infos
        ] + plugin_runfiles  # Proto files are not inputs, as they come via the descriptor sets
        tools = [protoc] + ([plugin_tool] if plugin_tool else [])

        # Amend command with debug options
        if verbose > 0:
            print("{}:".format(mnemonic), protoc.path, args)

        if verbose > 1:
            command += " && echo '\n##### SANDBOX AFTER RUNNING PROTOC' && find . -type f "

        if verbose > 2:
            command = "echo '\n##### SANDBOX BEFORE RUNNING PROTOC' && find . -type l && " + command

        if verbose > 3:
            command = "env && " + command
            for f in inputs:
                print("INPUT:", f.path)
            for f in protos:
                print("TARGET PROTO:", f.path)
            for f in tools:
                print("TOOL:", f.path)
            for f in plugin_outputs:
                print("EXPECTED OUTPUT:", f.path)

        # Run protoc
        ctx.actions.run_shell(
            mnemonic = mnemonic,
            command = command,
            arguments = [args],
            inputs = inputs,
            tools = tools,
            outputs = plugin_protoc_outputs,
            use_default_shell_env = plugin.use_built_in_shell_environment,
            input_manifests = plugin_input_manifests if plugin_input_manifests else [],
            progress_message = "Compiling protoc outputs for {} plugin on target {}".format(plugin.name, ctx.label),
        )

    # Bundle output
    return struct(
        output_root = output_root,
        output_files = output_files,
        output_dirs = output_dirs,
    )

def proto_compile_impl(ctx):
    if ctx.attr.protos and ctx.attr.deps:
        fail("Inputs provided to both 'protos' and 'deps' attrs of target {}. Use exclusively 'protos' or 'deps'".format(ctx.label))

    elif ctx.attr.protos:
        # Aggregate output files and dirs created by the aspect from the direct dependencies
        output_files_dicts = []
        for dep in ctx.attr.protos:
            aspect_node_info = dep[ProtoLibraryAspectNodeInfo]
            output_files_dicts.append({aspect_node_info.output_root: aspect_node_info.direct_output_files})

        output_dirs = depset(transitive = [
            dep[ProtoLibraryAspectNodeInfo].direct_output_dirs
            for dep in ctx.attr.protos
        ])

    elif ctx.attr.deps:
        # TODO: add link to below
        print("Inputs provided to 'deps' attr of target {}. Consider replacing with 'protos' attr to avoid transitive compilation".format(ctx.label))

        # Aggregate all output files and dirs created by the aspect as it has walked the deps. Legacy behaviour
        output_files_dicts = [dep[ProtoLibraryAspectNodeInfo].output_files for dep in ctx.attr.deps]
        output_dirs = depset(transitive = [
            dep[ProtoLibraryAspectNodeInfo].output_dirs
            for dep in ctx.attr.deps
        ])

    else:
        fail("No inputs provided to 'protos' attr of target {}".format(ctx.label))

    # Check merge_directories and prefix_path
    if not ctx.attr.merge_directories and ctx.attr.prefix_path:
        fail("Attribute prefix_path cannot be set when merge_directories is false")

    # Build outputs
    final_output_files = {}
    final_output_files_list = []
    final_output_dirs = depset()
    prefix_path = ctx.attr.prefix_path

    if not ctx.attr.merge_directories:
        # Pass on outputs directly when not merging
        for output_files_dict in output_files_dicts:
            final_output_files.update(**output_files_dict)
            final_output_files_list = [f for files in final_output_files.values() for f in files.to_list()]
        final_output_dirs = output_dirs

    elif output_dirs:
        # If we have any output dirs specified, we declare a single output
        # directory and merge all files in one go. This is necessary to prevent
        # path prefix conflicts

        # Declare single output directory
        dir_name = ctx.label.name
        if prefix_path:
            dir_name = dir_name + "/" + prefix_path
        new_dir = ctx.actions.declare_directory(dir_name)
        final_output_dirs = depset(direct = [new_dir])

        # Build copy command for directory outputs
        # Use cp {}/. rather than {}/* to allow for empty output directories from a plugin (e.g when no service exists,
        # so no files generated)
        command_parts = ["cp -r {} '{}'".format(
            " ".join(["'" + d.path + "/.'" for d in output_dirs.to_list()]),
            new_dir.path,
        )]

        # Extend copy command with file outputs
        command_input_files = []
        for output_files_dict in output_files_dicts:
            for root, files in output_files_dict.items():
                for file in files.to_list():
                    # Strip root from file path
                    path = strip_path_prefix(file.path, root)

                    # Prefix path is contained in new_dir.path created above and
                    # used below

                    # Add command to copy file to output
                    command_input_files.append(file)
                    command_parts.append("cp '{}' '{}'".format(
                        file.path,
                        "{}/{}".format(new_dir.path, path),
                    ))

        # Add debug options
        if ctx.attr.verbose > 1:
            command_parts = command_parts + ["echo '\n##### SANDBOX AFTER MERGING DIRECTORIES'", "find . -type l"]
        if ctx.attr.verbose > 2:
            command_parts = ["echo '\n##### SANDBOX BEFORE MERGING DIRECTORIES'", "find . -type l"] + command_parts
        if ctx.attr.verbose > 0:
            print("Directory merge command: {}".format(" && ".join(command_parts)))

        # Copy directories and files to shared output directory in one action
        ctx.actions.run_shell(
            mnemonic = "CopyDirs",
            inputs = depset(direct = command_input_files, transitive = [output_dirs]),
            outputs = [new_dir],
            command = " && ".join(command_parts),
            progress_message = "copying directories and files to {}".format(new_dir.path),
        )

    else:
        # Otherwise, if we only have output files, build the output tree by
        # aggregating files created by aspect into one directory

        output_root = get_package_root(ctx) + "/" + ctx.label.name

        for output_files_dict in output_files_dicts:
            for root, files in output_files_dict.items():
                for file in files.to_list():
                    # Strip root from file path
                    path = strip_path_prefix(file.path, root)

                    # Prepend prefix path if given
                    if prefix_path:
                        path = prefix_path + "/" + path

                    # Copy file to output
                    final_output_files_list.append(copy_file(
                        ctx,
                        file,
                        "{}/{}".format(ctx.label.name, path),
                    ))

        final_output_files[output_root] = depset(direct = final_output_files_list)

    # Create depset containing all outputs
    if ctx.attr.merge_directories:
        # If we've merged directories, we have copied files/dirs that are now direct rather than
        # transitive dependencies
        all_outputs = depset(direct = final_output_files_list + final_output_dirs.to_list())
    else:
        # If we have not merged directories, all files/dirs are transitive
        all_outputs = depset(
            transitive = [depset(direct = final_output_files_list), final_output_dirs],
        )

    # Create default and proto compile providers
    return [
        ProtoCompileInfo(
            label = ctx.label,
            output_files = final_output_files,
            output_dirs = final_output_dirs,
        ),
        DefaultInfo(
            files = all_outputs,
            data_runfiles = ctx.runfiles(transitive_files = all_outputs),
        ),
    ]

def proto_compile_aspect_impl(target, ctx):
    # Load ProtoInfo of the current node
    if ProtoInfo not in target:  # Skip non-proto targets, which we may get intermingled prior to deps deprecation
        return []
    proto_info = target[ProtoInfo]

    # Build protoc compile actions
    compile_out = common_compile(ctx, [proto_info])

    # Generate providers
    transitive_infos = [dep[ProtoLibraryAspectNodeInfo] for dep in ctx.rule.attr.deps]
    output_files_dict = {}
    if compile_out.output_files:
        output_files_dict[compile_out.output_root] = depset(direct = compile_out.output_files)

    transitive_output_dirs = []
    for transitive_info in transitive_infos:
        output_files_dict.update(**transitive_info.output_files)
        transitive_output_dirs.append(transitive_info.output_dirs)

    return [
        ProtoLibraryAspectNodeInfo(
            output_root = compile_out.output_root,
            direct_output_files = depset(direct = compile_out.output_files),
            direct_output_dirs = depset(direct = compile_out.output_dirs),
            output_files = output_files_dict,
            output_dirs = depset(direct = compile_out.output_dirs, transitive = transitive_output_dirs),
        ),
    ]
