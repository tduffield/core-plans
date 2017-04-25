# Habitat Node.js Scaffolding

This is [Habitat
scaffolding](https://www.habitat.sh/docs/concepts-scaffolding/) for
[Node.js](https://nodejs.org/en/) software.

To use it add:

```
pkg_scaffolding=core/scaffolding-node
```

to your plan.

If you have set a `pkg_source`, it will try to use
[NPM](https://www.npmjs.com/) to build your package. If you don't, it will look
in `$SRC_PATH` for a package.json and attempt to build a package using those
files and dtata.

## Building

In a studio where /src is the [core-plans
repo](https://github.com/habitat-sh/core-plans), run `build scaffolding-node`.

## Running tests

Run:

```bash
hab pkg exec chef/inspec inspec exec scaffolding-node/test
```

This assumes that the `$HAB_ORIGIN` that is set in the studio is the same as the
origin of the scaffolding-node package that is installed and used to run the
tests.
