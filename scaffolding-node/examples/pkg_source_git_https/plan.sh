pkg_description="An example plan for scaffolding-node that installs a package from a git URL based on what's in pkg_source."
pkg_name=docco
pkg_origin=test-scaffolding-node
pkg_version=0.7.0
pkg_source=git+https://github.com/jashkenas/$pkg_name.git#$pkg_version
pkg_scaffolding=$HAB_ORIGIN/scaffolding-node
pkg_bin_dirs=(bin)
