_scaffolding_begin() {
  _setup_funcs
  _setup_vars

  pushd "$SRC_PATH" > /dev/null
  _detect_gemfile
  _detect_app_type
  _detect_missing_gems
  _detect_process_bins
  _update_vars
  _update_pkg_build_deps
  _update_pkg_deps
  _update_bin_dirs
  _update_svc_run
  popd > /dev/null
}

do_default_prepare() {
  local gem_dir gem_path

  # Determine Ruby engine, ABI version, and Gem path by running `ruby` itself.
  eval "$(ruby -rubygems -rrbconfig - <<-'EOF'
    puts "local ruby_engine=#{defined?(RUBY_ENGINE) ? RUBY_ENGINE : 'ruby'}"
    puts "local ruby_version=#{RbConfig::CONFIG['ruby_version']}"
    puts "local gem_path='#{Gem.path.join(':')}'"
EOF
)"

  # Strip out any home directory entries at the front of the gem path.
  gem_path=$(echo "$gem_path" | sed 's|^/root/\.gem/[^:]\{1,\}:||')
  # Compute gem directory where gems will be ultimately installed to
  gem_dir="$scaffolding_app_prefix/vendor/bundle/$ruby_engine/$ruby_version"
  # Compute gem directory where gems are initially installed to via Bundler
  _cache_gem_dir="$CACHE_PATH/vendor/bundle/$ruby_engine/$ruby_version"

  # Silence Bundler warning when run as root user
  export BUNDLE_SILENCE_ROOT_WARNING=1

  GEM_HOME="$gem_dir"
  build_line "Setting GEM_HOME=$GEM_HOME"
  GEM_PATH="$gem_dir:$gem_path"
  build_line "Setting GEM_PATH=$GEM_PATH"
  export GEM_HOME GEM_PATH
}

do_default_build() {
  # TODO fin: add cache loading of `$CACHE_PATH/vendor`

  scaffolding_bundle_install

  # build_line "Cleaning old cached gems"
  # _bundle clean --dry-run --force
  # TODO fin: add cache saving of `$CACHE_PATH/vendor`

  scaffolding_remove_gem_cache
  scaffolding_vendor_bundler
  scaffolding_fix_rubygems_shebangs
  scaffolding_setup_app_config
  scaffolding_setup_database_config
}

do_default_install() {
  scaffolding_install_app
  scaffolding_install_gems
  scaffolding_generate_binstubs
  scaffolding_install_bundler_binstubs
  scaffolding_fix_binstub_shebangs
  scaffolding_run_assets_precompile
  scaffolding_create_dir_symlinks
  scaffolding_create_files_symlinks
  scaffolding_create_process_bins
}

# This becomes the `do_default_build_config` implementation thanks to some
# function "renaming" above. I know, right?
_new_do_default_build_config() {
  local key dir env_sh

  _stock_do_default_build_config

  if [[ ! -f "$PLAN_CONTEXT/hooks/init" ]]; then
    build_line "No user-defined init hook found, generating init hook"
    mkdir -p "$pkg_prefix/hooks"
    cat <<EOT >> "$pkg_prefix/hooks/init"
#!/bin/sh
set -e

if [ -f "$pkg_svc_config_path/hab_env.sh" ]; then
  . '$pkg_svc_config_path/hab_env.sh'
fi

$(
  case "$_app_type" in
    (rails5|rails42|rails41)
      cat <<_RAILS_
# Check that the 'SECRET_KEY_BASE' environment variable is non-empty
if [ -z "\${SECRET_KEY_BASE:-}" ]; then
  >&2 echo "Required environment variable SECRET_KEY_BASE is not set."
  >&2 echo "Set this package's config setting 'secret_key_base' to a"
  >&2 echo "non-empty value. You can run 'rails secret' in development"
  >&2 echo "to generate a random key string."
  >&2 echo ""
  >&2 echo "Aborting..."
  exit 5
fi
_RAILS_
      ;;
  esac
)

# Create a directory for each app symlinked dir under $pkg_svc_var_path
$(
  for dir in "${scaffolding_symlinked_dirs[@]}"; do
    echo "mkdir -pv '$pkg_svc_var_path/$dir'"
  done
)
EOT
    chmod 755 "$pkg_prefix/hooks/init"
  fi

  if [[ -f "$CACHE_PATH/default.scaffolding.toml" ]]; then
    build_line "Appending Scaffolding defaults to $pkg_prefix/default.toml"
    cat "$CACHE_PATH/default.scaffolding.toml" >> "$pkg_prefix/default.toml"
  fi

  env_sh="$pkg_prefix/config/hab_env.sh"
  mkdir -p "$(dirname "$env_sh")"
  for key in "${!scaffolding_env[@]}"; do
    echo "export $key='${scaffolding_env[$key]}'" >> "$env_sh"
  done
}




scaffolding_bundle_install() {
  local start_sec elapsed dot_bundle

  # Attempt to preserve any original Bundler config by moving it to the side
  if [[ -f .bundle/config ]]; then
    mv .bundle/config .bundle/config.prehab
    dot_bundle=true
  elif [[ -d .bundle ]]; then
    dot_bundle=true
  fi

  build_line "Installing dependencies using $(_bundle --version)"
  start_sec="$SECONDS"
  _bundle_install \
    "$CACHE_PATH/vendor/bundle" \
    --retry 5
  elapsed=$((SECONDS - start_sec))
  elapsed=$(echo $elapsed | awk '{printf "%dm%ds", $1/60, $1%60}')
  build_line "Bundle completed ($elapsed)"

  # If we preserved the original Bundler config, move it back into place
  if [[ -f .bundle/config.prehab ]]; then
    rm -f .bundle/config
    mv .bundle/config.prehab .bundle/config
    rm -f .bundle/config.prehab
  fi
  # If not `.bundle/` directory existed before, then clear it out now
  if [[ -z "${dot_bundle:-}" ]]; then
    rm -rf .bundle
  fi
}

scaffolding_remove_gem_cache() {
  build_line "Removing installed gem cache"
  rm -rf "$_cache_gem_dir/cache"
}

scaffolding_vendor_bundler() {
  build_line "Vendoring $(_bundle --version)"
  gem install \
    --local "$(pkg_path_for bundler)/cache/bundler-${_bundler_version}.gem" \
    --install-dir "$_cache_gem_dir" \
    --bindir "$CACHE_PATH/bundler" \
    --no-ri \
    --no-rdoc
  _wrap_ruby_bin "$CACHE_PATH/bundler/bundle"
  _wrap_ruby_bin "$CACHE_PATH/bundler/bundler"
}

scaffolding_fix_rubygems_shebangs() {
  local shebang
  shebang="#!$(pkg_path_for "$_ruby_pkg")/bin/ruby"

  build_line "Fixing Ruby shebang for RubyGems bins"
  find "$_cache_gem_dir/bin" -type f | while read -r bin; do
    sed -e "s|^#!.\{0,\}\$|${shebang}|" -i "$bin"
  done
}

scaffolding_setup_app_config() {
    # TODO fin: check with `rq` to see if these values have been set by
    # Plan author
    cat <<EOT >> "$CACHE_PATH/default.scaffolding.toml"

$(
  if [[ -v scaffolding_env[SECRET_KEY_BASE] ]]; then
    echo "# Rails' secret key base is required and must be non-empty"
    echo "# You can run 'rails secret' in development to generate"
    echo "# a random key string."
    echo 'secret_key_base = ""'
    echo ""
  fi
)
lang = "en_US.UTF-8"
$(
  if [[ -v scaffolding_env[RACK_ENV] ]]; then
    echo 'rack_env = "production"'
  fi
)
$(
  if [[ -v scaffolding_env[RAILS_ENV] ]]; then
    echo 'rails_env = "production"'
  fi
)

[app]
port = $scaffolding_app_port
EOT
}

scaffolding_setup_database_config() {
  if [[ "${_uses_pg:-}" == "true" ]]; then
    local db
    # TODO fin: handle leader selection vs. choosing the first in a service
    # group
    db="postgres://{{cfg.db.user}}:{{cfg.db.password}}"
    db="${db}@{{bind.database.first.sys.ip}}:{{bind.database.first.cfg.port}}"
    db="${db}/{{cfg.db.name}}"
    scaffolding_env[DATABASE_URL]="$db"

    # Add a require binding called `database` which will be the PostgreSQL
    # database
    pkg_binds[database]="port"

    # TODO fin: check with `rq` to see if these values have been set by
    # Plan author
    cat <<EOT >> "$CACHE_PATH/default.scaffolding.toml"

[db]
name = "${pkg_name}_production"
user = "$pkg_name"
password = "$pkg_name"
EOT
  fi
}

scaffolding_install_app() {
  build_line "Installing app codebase to $scaffolding_app_prefix"
  mkdir -pv "$scaffolding_app_prefix"
  if [[ -n "${_uses_git:-}" ]]; then
    # Use git commands to skip any git-ignored files and directories including
    # the `.git/ directory. Current on-disk state of all files is used meaning
    # that dirty and unstaged files are included which should help while
    # working on package builds.
    { git ls-files; git ls-files --exclude-standard --others; } \
      | _tar_pipe_app_cp_to "$scaffolding_app_prefix"
  else
    # Use find to enumerate all files and directories for copying. This is the
    # safe-fallback strategy if no version control software is detected.
    find . | _tar_pipe_app_cp_to "$scaffolding_app_prefix"
  fi
}

scaffolding_install_gems() {
  mkdir -pv "$scaffolding_app_prefix/vendor"
  build_line "Installing vendored gems to $scaffolding_app_prefix/vendor/bundle"
  cp -a "$CACHE_PATH/vendor/bundle" "$scaffolding_app_prefix/vendor/"
}

scaffolding_generate_binstubs() {
  build_line "Generating app binstubs in $scaffolding_app_prefix/binstubs"
  rm -rf "$scaffolding_app_prefix/.bundle"
  pushd "$scaffolding_app_prefix" > /dev/null
  _bundle_install \
    "$scaffolding_app_prefix/vendor/bundle" \
    --local \
    --quiet \
    --binstubs="$scaffolding_app_prefix/binstubs"
  popd > /dev/null
}

scaffolding_install_bundler_binstubs() {
  build_line "Installing Bundler binstubs to $scaffolding_app_prefix/binstubs"
  cp -a "$CACHE_PATH/bundler"/* "$scaffolding_app_prefix/binstubs"
}

scaffolding_fix_binstub_shebangs() {
  local shebang
  shebang="#!$(pkg_path_for "$_ruby_pkg")/bin/ruby"

  build_line "Fixing Ruby shebang for binstubs"
  find "$scaffolding_app_prefix/binstubs" -type f | while read -r binstub; do
    if grep -q '^#!/usr/bin/env /.*/bin/ruby$' "$binstub"; then
      sed -e "s|^#!/usr/bin/env /.\{0,\}/bin/ruby\$|${shebang}|" -i "$binstub"
    fi
  done
}

scaffolding_run_assets_precompile() {
  # TODO fin: early exit if existing assets are found, meaning they've been
  # committed or at least not ignored.

  if _has_gem rake && _has_rakefile; then
    pushd "$scaffolding_app_prefix" > /dev/null
    if _rake -P --trace | grep -q '^rake assets:precompile$'; then
      build_line "Detected and running Rake 'assets:precompile'"
      _rake assets:precompile
    fi
    popd > /dev/null
  fi
}

scaffolding_create_dir_symlinks() {
  local entry dir target

  for entry in "${scaffolding_symlinked_dirs[@]}"; do
    dir="$scaffolding_app_prefix/$entry"
    target="$pkg_svc_var_path/$entry"
    build_line "Creating directory symlink to '$target' for '$dir'"
    rm -rf "$dir"
    mkdir -p "$(dirname "$dir")"
    ln -sfv "$target" "$dir"
  done
}

scaffolding_create_files_symlinks() {
  return 0
}

scaffolding_create_process_bins() {
  local bin cmd

  mkdir -pv "$CACHE_PATH/process_bins"
  for bin in "${!scaffolding_process_bins[@]}"; do
    cmd="${scaffolding_process_bins[$bin]}"
    _create_process_bin "$pkg_prefix/bin/${pkg_name}-${bin}" "$cmd"
  done
}




_setup_funcs() {
  # Use the stock `do_default_build_config` by renaming it so we can call the
  # stock behavior. How does this rate on the evil scale?
  _rename_function "do_default_build_config" "_stock_do_default_build_config"
  _rename_function "_new_do_default_build_config" "do_default_build_config"
}

_setup_vars() {
  # The default Ruby package if one cannot be detected
  _default_ruby_pkg="core/ruby"
  # The absolute path to the `gemfile-parser` program
  _gemfile_parser="$(pkg_path_for scaffolding-ruby)/bin/gemfile-parser"
  # `$scaffolding_ruby_pkg` is empty by default
  : "${scaffolding_ruby_pkg:=}"
  # The list of PostgreSQL-related gems
  _pg_gems=(pg activerecord-jdbcpostgresql-adapter jdbc-postgres
    jdbc-postgresql jruby-pg rjack-jdbc-postgres
    tgbyte-activerecord-jdbcpostgresql-adapter)
  # The version of Bundler in use
  _bundler_version="$("$(pkg_path_for bundler)/bin/bundle" --version \
    | awk '{print $NF}')"
  # The install prefix path for the app
  scaffolding_app_prefix="$pkg_prefix/app"
  #
  : "${scaffolding_app_port:=8000}"
  # If `${scaffolding_env[@]` is not yet set, setup the hash
  if [[ ! "$(declare -p scaffolding_env 2> /dev/null || true)" =~ "declare -A" ]]; then
    declare -g -A scaffolding_env
  fi
  # If `${scaffolding_process_bins[@]` is not yet set, setup the hash
  if [[ ! "$(declare -p scaffolding_process_bins 2> /dev/null || true)" =~ "declare -A" ]]; then
    declare -g -A scaffolding_process_bins
  fi
  #
  : "${scaffolding_symlinked_dirs:=()}"
  #
  : "${scaffolding_symlinked_files:=()}"
  #
  : "${_app_type:=}"
}

_detect_gemfile() {
  if [[ ! -f Gemfile ]]; then
    exit_with "Ruby Scaffolding cannot find Gemfile in the root directory" 5
  fi
  if [[ ! -f Gemfile.lock ]]; then
    local uid gid
    build_line "No Gemfile.lock found, running 'bundle lock'"
    "$(pkg_path_for bundler)/bin/bundle" lock
    # Set ownership of `Gemfile.lock` to be the same as `Gemfile`.
    uid="$(stat -c "%u" Gemfile)"
    gid="$(stat -c "%g" Gemfile)"
    chown -v "${uid}:${gid}" Gemfile.lock
  fi
}

_detect_app_type() {
  _detect_rails5_app \
    || _detect_rails42_app \
    || _detect_rails41_app \
    || _detect_rails4_app \
    || _detect_rails3_app \
    || _detect_rails2_app \
    || _detect_rack_app \
    || _detect_ruby_app
}

_detect_missing_gems() {
  if [[ "$_app_type" == "rails5" ]] && ! _has_gem tzinfo-data; then
    local e
    e="A required gem 'tzinfo-data' is missing from the Gemfile."
    e="$e If a 'gem \"tzinfo-data\", platforms: [...]' line exists,"
    e="$e simply remove the comma and 'platforms:' section,"
    e="$e run 'bundle update' to update the Gemfile.lock, and retry the build."
    exit_with "$e" 10
  fi
}

_detect_process_bins() {
  if [[ -f Procfile ]]; then
    local line bin cmd

    build_line "Procfile detected, reading processes"
    # Procfile parsing was heavily inspired by the implementation in
    # gliderlabs/herokuish. Thanks to:
    # https://github.com/gliderlabs/herokuish/blob/master/include/procfile.bash
    while read -r line; do
      if [[ "$line" =~ ^#.* ]]; then
        continue
      else
        bin="${line%%:*}"
        cmd="${line#*:}"
        _set_process_bin_if_empty "$(trim $bin)" "$(trim $cmd)"
      fi
    done < Procfile
  fi

  case "$_app_type" in
    rails*)
      _set_process_bin_if_empty "web" 'bundle exec rails server -p $PORT'
      _set_process_bin_if_empty "console" 'bundle exec rails console'
      ;;
    rack)
      _set_process_bin_if_empty "web" 'bundle exec rackup config.ru -p $PORT'
      _set_process_bin_if_empty "console" 'bundle exec irb'
      ;;
  esac
  if _has_gem rake && _has_rakefile; then
    _set_process_bin_if_empty "rake" 'bundle exec rake'
  fi
  _set_process_bin_if_empty "sh" 'sh'
}

_update_vars() {
  scaffolding_env[LANG]="{{cfg.lang}}"
  scaffolding_env[PORT]="{{cfg.app.port}}"
  # Export the app's listen port
  pkg_exports[port]="app.port"

  case "$_app_type" in
    rails*)
      scaffolding_symlinked_dirs+=(log tmp public/system)
      if _compare_gem railties --less-than 4.1.0; then
        scaffolding_symlinked_files+=(config/secrets.yml)
      fi

      scaffolding_env[RAILS_ENV]="{{cfg.rails_env}}"
      scaffolding_env[RACK_ENV]="{{cfg.rack_env}}"
      if _compare_gem railties --greater-than-eq 5.0.0; then
        scaffolding_env[RAILS_LOG_TO_STDOUT]="enabled"
      fi
      if _compare_gem railties --greater-than-eq 4.2.0; then
        scaffolding_env[RAILS_SERVE_STATIC_FILES]="enabled"
      fi
      if _compare_gem railties --greater-than-eq 4.1.0; then
        scaffolding_env[SECRET_KEY_BASE]="{{cfg.secret_key_base}}"
      fi
      ;;
    rack)
      scaffolding_env[RACK_ENV]="{{cfg.rack_env}}"
      ;;
  esac

  if _has_gem activerecord && _compare_gem activerecord \
      --less-than 4.1.0.beta1; then
    scaffolding_symlinked_files+=(config/database.yml)
  fi
}

_update_pkg_build_deps() {
  # Order here is important--entries which should be first in
  # `${pkg_build_deps[@]}` should be called last.

  _detect_git
}

_update_pkg_deps() {
  # Order here is important--entries which should be first in `${pkg_deps[@]}`
  # should be called last.

  _add_busybox
  _detect_sqlite3
  _detect_pg
  _detect_nokogiri
  _detect_execjs
  _detect_webpacker
  _detect_ruby
}

_update_bin_dirs() {
  # Add the `bin/` directory and the app's `binstubs/` directory to the bin
  # dirs so they will be on `PATH.  We do this after the existing values so
  # that the Plan author's `${pkg_bin_dir[@]}` will always win.
  pkg_bin_dirs=(
    ${pkg_bin_dir[@]}
    bin
    $(basename "$scaffolding_app_prefix")/binstubs
  )
}

_update_svc_run() {
  if [[ -z "$pkg_svc_run" ]]; then
    pkg_svc_run="$pkg_prefix/bin/${pkg_name}-web"
    build_line "Setting pkg_svc_run='$pkg_svc_run'"
  fi
}




_add_busybox() {
  build_line "Adding Busybox package to run dependencies"
  pkg_deps=(core/busybox-static ${pkg_deps[@]})
  debug "Updating pkg_deps=(${pkg_deps[*]}) from Scaffolding detection"
}

_detect_execjs() {
  if _has_gem execjs; then
    build_line "Detected 'execjs' gem in Gemfile.lock, adding node packages"
    pkg_deps=(core/node ${pkg_deps[@]})
    debug "Updating pkg_deps=(${pkg_deps[*]}) from Scaffolding detection"
  fi
}

_detect_git() {
  if [[ -d ".git" ]]; then
    build_line "Detected '.git' directory, adding git packages as build deps"
    pkg_build_deps=(core/git ${pkg_build_deps[@]})
    debug "Updating pkg_build_deps=(${pkg_build_deps[*]}) from Scaffolding detection"
    _uses_git=true
  fi
}

_detect_nokogiri() {
  if _has_gem nokogiri; then
    build_line "Detected 'nokogiri' gem in Gemfile.lock, adding libxml2 & libxslt packages"
    export BUNDLE_BUILD__NOKOGIRI="--use-system-libraries"
    pkg_deps=(core/libxml2 core/libxslt ${pkg_deps[@]})
    debug "Updating pkg_deps=(${pkg_deps[*]}) from Scaffolding detection"
  fi
}

_detect_pg() {
  for gem in "${_pg_gems[@]}"; do
    if _has_gem "$gem"; then
      build_line "Detected '$gem' gem in Gemfile.lock, adding postgresql package"
      pkg_deps=(core/postgresql ${pkg_deps[@]})
      debug "Updating pkg_deps=(${pkg_deps[*]}) from Scaffolding detection"
      _uses_pg=true
      return 0
    fi
  done
}

_detect_rack_app() {
  if _has_gem rack; then
    build_line "Detected Rack app type"
    _app_type="rack"
    return 0
  else
    return 1
  fi
}

_detect_rails2_app() {
  if _has_gem railties && _compare_gem railties \
      --greater-than-eq 2.0.0 --less-than 3.0.0; then
    build_line "Detected Rails 2 app type"
    warn "Rails 2 app types not yet supported with this Scaffolding"
    exit_with "App type not supported" 2
    _app_type="rails2"
    return 0
  else
    return 1
  fi
}

_detect_rails3_app() {
  if _has_gem railties && _compare_gem railties \
      --greater-than-eq 3.0.0 --less-than 4.0.0; then
    build_line "Detected Rails 3 app type"
    warn "Rails 3 app types not yet supported with this Scaffolding"
    exit_with "App type not supported" 2
    _app_type="rails3"
    return 0
  else
    return 1
  fi
}

_detect_rails4_app() {
  if _has_gem railties && _compare_gem railties \
      --greater-than-eq 4.0.0.beta --less-than 4.1.0.beta1; then
    build_line "Detected Rails 4 app type"
    warn "Rails 4 app types not yet supported with this Scaffolding"
    exit_with "App type not supported" 2
    _app_type="rails4"
    return 0
  else
    return 1
  fi
}

_detect_rails41_app() {
  if _has_gem railties && _compare_gem railties \
      --greater-than-eq 4.1.0.beta1 --less-than 5.0.0; then
    build_line "Detected Rails 4.1 app type"
    warn "Rails 4.1 app types not yet supported with this Scaffolding"
    exit_with "App type not supported" 2
    _app_type="rails41"
    return 0
  else
    return 1
  fi
}

_detect_rails42_app() {
  if _has_gem railties && _compare_gem railties \
      --greater-than-eq 4.2.0 --less-than 5.0.0; then
    build_line "Detected Rails 4.2 app type"
    warn "Rails 4.2 app types not yet supported with this Scaffolding"
    exit_with "App type not supported" 2
    _app_type="rails42"
    return 0
  else
    return 1
  fi
}

_detect_rails5_app() {
  if _has_gem railties && _compare_gem railties \
      --greater-than-eq 5.0.0 --less-than 6.0.0; then
    build_line "Detected Rails 5 app type"
    _app_type="rails5"
    return 0
  else
    return 1
  fi
}

_detect_ruby_app() {
  build_line "Detected Ruby app type"
  warn "Ruby app types not yet supported with this Scaffolding"
  exit_with "App type not supported" 2
  _app_type="ruby"
  return 0
}

_detect_ruby() {
  local lockfile_version

  if [[ -n "$scaffolding_ruby_pkg" ]]; then
    _ruby_pkg="$scaffolding_ruby_pkg"
    build_line "Detected Ruby version in Plan, using '$_ruby_pkg'"
  else
    lockfile_version="$($_gemfile_parser ruby-version ./Gemfile.lock || true)"
    if [[ -n "$lockfile_version" ]]; then
      # TODO fin: Add more robust Gemfile to Habitat package matching
      case "$lockfile_version" in
        *)
          _ruby_pkg="core/ruby/$(
            echo "$lockfile_version" | cut -d ' ' -f 2)"
          ;;
      esac
      build_line "Detected Ruby version '$lockfile_version' in Gemfile.lock, using '$_ruby_pkg'"
    else
      _ruby_pkg="$_default_ruby_pkg"
      build_line "No Ruby version detected in Plan or Gemfile.lock, using default '$_ruby_pkg'"
    fi
  fi
  pkg_deps=($_ruby_pkg ${pkg_deps[@]})
  debug "Updating pkg_deps=(${pkg_deps[*]}) from Scaffolding detection"
}

_detect_sqlite3() {
  if _has_gem sqlite3; then
    build_line "Detected 'sqlite3' gem in Gemfile.lock, adding sqlite packages"
    pkg_deps=(core/sqlite ${pkg_deps[@]})
    debug "Updating pkg_deps=(${pkg_deps[*]}) from Scaffolding detection"
  fi
}

_detect_webpacker() {
  if _has_gem webpacker; then
    build_line "Detected 'webpacker' gem in Gemfile.lock, adding yarn packages"
    pkg_deps=(core/yarn ${pkg_deps[@]})
    debug "Updating pkg_deps=(${pkg_deps[*]}) from Scaffolding detection"
  fi
}




# **Internal** Invokes the `bundle` program using the chosen version of Ruby.
# This way, we should avoid most Bundler warnings about mismatched Ruby
# versions specfied in the Gemfile.
_bundle() {
  local bundler_prefix
  bundler_prefix="$(pkg_path_for bundler)"

  env \
    -u RUBYOPT \
    -u GEMRC \
    GEM_HOME="$bundler_prefix" \
    GEM_PATH="$bundler_prefix" \
    "$(pkg_path_for "$_ruby_pkg")/bin/ruby" \
    "$bundler_prefix/bin/bundle.real" ${*:-}
}

_rake() {
  case "$_app_type" in
    rails*)
      RACK_ENV=production \
        RAILS_ENV=production \
        RAILS_GROUP=assets \
        _bundle exec rake ${*:-}
      ;;
    rack)
      RACK_ENV=production \
        _bundle exec rake ${*:-}
      ;;
    *)
      _bundle exec rake ${*:-}
      ;;
  esac
}

_bundle_install() {
  local path
  path="$1"
  shift

  _bundle install ${*:-} \
    --jobs "$(nproc)" \
    --without development:test \
    --path "$path" \
    --shebang="$(pkg_path_for "$_ruby_pkg")/bin/ruby" \
    --no-clean \
    --deployment
}

_compare_gem() {
  local gem result
  gem="$1"
  shift

  result="$($_gemfile_parser compare-gem-version ${*:-} \
    ./Gemfile.lock "$gem" 2> /dev/null || true)"

  if [[ "$result" == "true" ]]; then
    return 0
  else
    return 1
  fi
}

_create_process_bin() {
  local bin cmd env_sh
  bin="$1"
  cmd="$2"
  env_sh="$pkg_svc_config_path/hab_env.sh"

  build_line "Creating ${bin} process bin"
  cat <<EOF > "$bin"
#!$(pkg_path_for busybox-static)/bin/sh
set -e
if test -n "\$DEBUG"; then set -x; fi

if [ -f "$env_sh" ]; then
  . "$env_sh"
else
  >&2 echo "No app env file found: '$env_sh'"
  >&2 echo "Have you not started this service ($pkg_origin/$pkg_name) before?"
  >&2 echo ""
  >&2 echo "Aborting..."
  exit 1
fi

cd $scaffolding_app_prefix

exec $cmd \$@
EOF
  chmod -v 755 "$bin"
}

_has_gem() {
  local result
  result="$($_gemfile_parser has-gem ./Gemfile.lock "$1" 2> /dev/null || true)"

  if [[ "$result" == "true" ]]; then
    return 0
  else
    return 1
  fi
}

_has_rakefile() {
  local candidate candidates
  candidates=(Rakefile rakefile rakefile.rb Rakefile.rb)

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      return 0
    fi
  done
  return 1
}

# Heavily inspired from:
# https://gist.github.com/Integralist/1e2616dc0b165f0edead9bf819d23c1e
_rename_function() {
  local orig_name new_name
  orig_name="$1"
  new_name="$2"

  declare -F "$orig_name" > /dev/null \
    || exit_with "No function named $orig_name, aborting" 97
  eval "$(echo "${new_name}()"; declare -f "$orig_name" | tail -n +2)"
}

_set_process_bin_if_empty() {
  local bin cmd
  bin="$1"
  cmd="$2"

  if [[ ! -v "scaffolding_process_bins[$bin]" ]]; then
    scaffolding_process_bins[$bin]="$cmd"
  fi
}

# **Internal** Use a "tar pipe" to copy the app source into a destination
# directory. This function reads from `stdin` for its file/directory manifest
# where each entry is on its own line ending in a newline. Several filters and
# changes are made via this copy strategy:
#
# * All user and group ids are mapped to root/0
# * No extended attributes are copied
# * Some file editor backup files are skipped
# * Some version control-related directories are skipped
# * Any `./habitat/` directory is skipped
# * Any `./vendor/bundle` directory is skipped as it may have native gems
_tar_pipe_app_cp_to() {
  local dst_path tar
  dst_path="$1"
  tar="$(pkg_path_for tar)/bin/tar"

  "$tar" -cp \
      --owner=root:0 \
      --group=root:0 \
      --no-xattrs \
      --exclude-backups \
      --exclude-vcs \
      --exclude='habitat' \
      --exclude='vendor/bundle' \
      --files-from=- \
      -f - \
  | "$tar" -x \
      -C "$dst_path" \
      -f -
}

_wrap_ruby_bin() {
  local bin="$1"
  build_line "Adding wrapper $bin to ${bin}.real"
  mv -v "$bin" "${bin}.real"
  cat <<EOF > "$bin"
#!$(pkg_path_for busybox-static)/bin/sh
set -e
if test -n "\$DEBUG"; then set -x; fi

export GEM_HOME="$GEM_HOME"
export GEM_PATH="$GEM_PATH"
unset RUBYOPT GEMRC

exec $(pkg_path_for $_ruby_pkg)/bin/ruby ${bin}.real \$@
EOF
  chmod -v 755 "$bin"
}
