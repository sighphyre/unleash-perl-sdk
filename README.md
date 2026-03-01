# Perl SDK Shell

Library-first Perl scaffold.

## Layout

- `lib/Srv/SDK.pm`: library module
- `bin/hello.pl`: tiny runnable example using the library
- `t/basic.t`: basic module test

## Run Example

```sh
./bin/hello.pl
```

## Run Tests

```sh
prove -I lib t
```

## Install The Library

### Option 1: ExtUtils::MakeMaker (classic)

```sh
perl Makefile.PL
make
make test
```

Install for your current user/project path (no sudo):

```sh
make install INSTALL_BASE=$PWD/.local
```

Then use it in this shell:

```sh
export PERL5LIB="$PWD/.local/lib/perl5:$PERL5LIB"
```

### Option 2: cpanm from local directory

```sh
cpanm --installdeps .
cpanm --local-lib-contained "$PWD/.local" .
```

Then use it in this shell:

```sh
export PERL5LIB="$PWD/.local/lib/perl5:$PERL5LIB"
export PATH="$PWD/.local/bin:$PATH"
```
