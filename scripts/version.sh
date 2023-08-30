#!/bin/sh

## This script is not meant to be executed interactively. Instead it is meant to
## be used in other scripts to provide common variables for version numbers and
## hashes.
##
## Typical use:
## . "$script_dir"/version.sh

## `ocaml-version` should be in sync with `README.rst` and
## `lib.protocol-compiler/octez-protocol-compiler.opam`
##
## This script is also sourced in the Makefile, as such it should be compatible
## with both the make and sh syntax

export ocaml_version=4.14.1
export opam_version=2
export recommended_rust_version=1.64.0
export recommended_node_version=16.18.1

## full_opam_repository is a commit hash of the public OPAM repository, i.e.
## https://github.com/ocaml/opam-repository
export full_opam_repository_tag=07d02c51140fe8374190e2c8b7ae52b3d207ea2c

## opam_repository is an additional, tezos-specific opam repository.
## This value MUST be the same as `build_deps_image_version` in `.gitlab-ci.yml`
export opam_repository_url=https://gitlab.com/tezos/opam-repository
export opam_repository_tag="${OPAM_REPOSITORY_TAG:-0956fe2a50734835c84e1a1f5bedd2e78e3954c4}"
export opam_repository_git="$opam_repository_url.git"
export opam_repository="$opam_repository_git"\#"$opam_repository_tag"

## Other variables, used both in Makefile and scripts
export COVERAGE_OUTPUT=_coverage_output

## The version of the rust-specific image which can be used to build Rust
## artifacts of this repository.
export rust_toolchain_image_version="v1.0.3"
