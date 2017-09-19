"""Haskell Rules

These build rules are used for building Haskell projects with Bazel.
"""

# Current implementation approach is to re-implement Cabal in Bazel and rely
# on `--make`.

# An alternative approach might be to insist that each and every module be
# specified. I think we might get that as an option "for free".

HASKELL_FILETYPE = ["hs", "lhs"]

def _haskell_toolchain(ctx):
  # TODO: Assemble this from something like 'repositories', which fetches the
  # toolchain and uses that to build things, rather than assuming a system GHC
  # is installed.
  return struct(
    ghc_path = "ghc",
  )

def _hs_module_impl(ctx):
  """A single Haskell module.

  At the moment this only really works with a single file in srcs.
  """
  # Using new_file here instead of ctx.outputs to keep it reusable within
  # _hs_binary_impl
  toolchain = _haskell_toolchain(ctx)
  out_o = ctx.new_file(ctx.label.name + ".o")
  out_hi = ctx.new_file(ctx.label.name + ".hi")
  ctx.action(
      inputs = ctx.files.srcs + ctx.files.deps + ctx.files.data,
      outputs = [out_o, out_hi],
      command = " ".join([
          "HOME=/fake", toolchain.ghc_path, "-c",
          "-o", out_o.path,
          "-ohi", out_hi.path,
          "-i",
          "-i%s" % ctx.configuration.bin_dir.path,  # <-- not entirely correct
          cmd_helper.join_paths(" ", set(ctx.files.srcs))
      ]),
      use_default_shell_env = True,
  )
  return struct(obj = out_o,
                interface = out_hi)


def _change_extension(file_object, new_extension):
  """Return the basename of 'file_object' with a new extension."""
  return file_object.basename[:-len(file_object.extension)] + new_extension

# XXX: Possibly rename this to hs_package, since it's unclear what "building a
# Haskell library" means without the package system, and since jml can't find
# a documented way to use libraries without interacting with the package
# database.
def _hs_library_impl(ctx):
  """A Haskell library."""
  toolchain = _haskell_toolchain(ctx)
  object_files = []
  interface_files = []
  for src in ctx.files.srcs:
    if src.extension not in HASKELL_FILETYPE:
      # XXX: We probably want to allow srcs that aren't Haskell files (genrule
      # results? *.o files?). For now, keeping it simple.
      fail("Can only build Haskell libraries from source files: %s" % (src.path,))

    object_files.append(ctx.actions.declare_file(_change_extension(src, 'o'), sibling=src))
    interface_files.append(ctx.actions.declare_file(_change_extension(src, 'hi'), sibling=src))

  # XXX: Unclear whether it would be better to have one action per *.hs file
  # or just one action which takes all *.hs files and compiles them.

  # XXX: Related: Unclear whether we should use '--make' and let GHC figure out
  # dependencies or whether instead we should encourage per-module rules.
  ghc_args = [
    '-c',  # So we just compile things, no linking
    '--make',  # Let GHC figure out dependencies
    '-i',  # Empty the import directory list
    # XXX: stack also includes
    # -ddump-hi
    # -ddump-to-file
    # -fbuilding-cabal-package -- this just changes some warning text
    # -static  -- use static libraries, if possibly
    # -dynamic-too
    # -optP-include
    # -optP.stack-work/.../cabal_macros.h
    # -this-unit-id <label-name>-<version>-<thigummy>
    #
    # - various output dir controls
    # - various package db controls
    #
    # Also what about...
    # - optimizations
    # - warnings
    # - concurrent builds (-j4)
    # - -threaded (I guess only relevant for executables)
  ]
  ctx.actions.run(
    inputs = ctx.files.srcs,
    outputs = object_files + interface_files,
    executable = toolchain.ghc_path,
    # XXX: Is it OK to rely on `ghc` sending output to same directory?
    arguments = ghc_args + [f.path for f in ctx.files.srcs],
    progress_message = ("Compiling Haskell library %s (%d files)"
                        % (ctx.label.name, len(ctx.attr.srcs))),
    mnemonic = 'HsCompile',
    use_default_shell_env = True,  # TODO: Figure out how we can do without this.
  )

  # https://downloads.haskell.org/~ghc/latest/docs/html/users_guide/packages.html#building-a-package-from-haskell-source
  # ar cqs libHSfoo-1.0.a A.o B.o C.o ...
  # XXX: jml doesn't know what these arguments mean, nor whether they work on macOS.
  # stack uses '-r -s' on macOS
  ar_args = ['cqs']
  hs_lib = ctx.outputs.hs_lib
  print([f.path for f in object_files])
  ctx.actions.run(
    inputs = object_files,
    outputs = [hs_lib],
    executable = ctx.fragments.cpp.ar_executable,
    arguments = ar_args + [hs_lib.path] + [f.path for f in object_files],
    progress_message = ("Linking Haskell library %s (%d files)"
                        % (ctx.label.name, len(object_files))),
    mnemonic = 'HsLink',
  )
  # XXX: jml doesn't know what to return from here. Cargo culting from rust.
  return struct(
    hs_lib = hs_lib,
  )


def _hs_binary_impl(ctx):
  # XXX: This is wrong. We don't want to build a library for a binary, nor do
  # we want to build a single module. Rather, we want to compile all of the
  # sources to objects and then use GHC to build an executable from those.
  lib_self = _hs_module_impl(ctx)
  objects = [x.obj for x in ctx.attr.deps] + [lib_self.obj]
  toolchain = _haskell_toolchain(ctx)
  ctx.action(
      inputs = objects + ctx.files.data,
      outputs = [ctx.outputs.executable],
      command = " ".join([
          "HOME=/fake", toolchain.ghc_path,
          "-o", ctx.outputs.executable.path,
          cmd_helper.join_paths(" ", set(objects))
      ]),
      use_default_shell_env = True,
  )

_hs_attrs = {
    "srcs": attr.label_list(
        allow_files = HASKELL_FILETYPE,
    ),
    "deps": attr.label_list(
        allow_files = False,
    ),
    "data": attr.label_list(
        allow_files = True,
    ),
}

hs_module = rule(
    attrs = _hs_attrs,
    outputs = {
        "obj": "%{name}.o",
        "interface": "%{name}.hi",
    },
    implementation = _hs_module_impl,
)

hs_library = rule(
  attrs = _hs_attrs,
  fragments = ["cpp"],
  implementation = _hs_library_impl,
  outputs = {
    "hs_lib": "libHS%{name}.a",
  },
)

hs_binary = rule(
    attrs = _hs_attrs,
    executable = True,
    implementation = _hs_binary_impl,
)
