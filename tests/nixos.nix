{ modules ? [ ], nixpkgs, system, ... }:

let
  pkgs = nixpkgs.legacyPackages.${system};
in
pkgs.nixosTest ({ lib, system, ... }:

let
  persistenceSupportsRootOption =
    let
      dummySystem = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = modules ++ [

          { config.environment.persistence."/123".directories = [ "/456" ]; }
        ];
      };
      firstDir = lib.head (dummySystem.config.environment.persistence."/123".directories);
    in
    firstDir ? root;
in
{
  name = "impermanence";

  nodes.machine = { lib, ... }: {
    imports = modules;

    config = {
      virtualisation.fileSystems = lib.mkIf (!persistenceSupportsRootOption) {
        "/abc" = { fsType = "tmpfs"; neededForBoot = true; };
        "/def" = { fsType = "tmpfs"; neededForBoot = true; };
      };

      system.activationScripts.signalPersistenceSetupComplete = {
        deps = [ "persist-files" ];
        text = ''
          touch /run/.persistence-setup-complete
        '';
      };

      users =
        let
          mkNormalUser = spec:
            let
              attrs = if lib.isAttrs spec then spec else { name = spec; };
              inherit (attrs) name;
            in
            {
              users.${name} = { group = name; isNormalUser = true; } // (removeAttrs attrs [ "name" ]);
              groups.${name} = { };
            };

          mkNormalUsers = lib.foldl (final: name: lib.recursiveUpdate final (mkNormalUser name)) { };
        in
        mkNormalUsers [
          { name = "me"; home = "/althome/me"; }
          "you"
          "alex"
          "benny"
          "cat"
          "del"
        ];

      environment.persistence = {
        "/abc" = {
          enableDebugging = true;

          directories = [
            { directory = "/foo/bar/bazz/luhrmann"; mode = "0777"; user = "del"; group = "del"; }
            { directory = "/foo/bar/bazz"; mode = "0700"; user = "benny"; group = "benny"; }
            { directory = "/one/two/three"; mode = "0755"; user = "cat"; group = "cat"; }
          ] ++ (lib.optionals persistenceSupportsRootOption [
            { directory = "/one/two/three"; root = "/here"; mode = "0755"; user = "cat"; group = "cat"; }
            { directory = "/one/two/three"; root = "/there"; mode = "0755"; user = "cat"; group = "cat"; }
          ]);

          users = {
            me = {
              home = "/althome/me";

              directories = [
                { directory = "/dotfiles"; mode = "0700"; }
              ];

              files = [
                { file = "dotfiles/.dotfilesrc"; parentDirectory = { mode = "0755"; }; }
              ];
            };
          };
        };

        "/def" = {
          enableDebugging = true;

          directories = [
            { directory = "/foo/bar/bazz/quux"; mode = "0755"; user = "alex"; group = "alex"; }
            { directory = "/one/two/three/four"; mode = "0750"; user = "del"; group = "del"; }
          ];

          files = [
            { file = "/one/two/three/go"; }
          ];

          users = {
            me = {
              home = "/althome/me";

              files = [
                { file = ".merc"; }
              ];
            };

            you = {
              files = [
                # XXX the mode set on the parent directory is *ignored* because
                # `/home/you` will already exist at the time
                # `create-directories.bash` runs.
                { file = ".yourc"; parentDirectory.mode = "0755"; }
              ];
            };
          };
        };
      };
    };
  };

  testScript = ''
    import shlex

    def assert_stat(machine, path, type, mode=None, user=None, group=None):
      stat_fmt = ['%F']
      checks = [('type', type)]

      if mode is not None:
        stat_fmt.append('%#a')
        checks.append(('mode', mode))

      if user is not None:
        stat_fmt.append('%U')
        checks.append(('user', user))

      if group is not None:
        stat_fmt.append('%G')
        checks.append(('group', group))

      printf_arg = '\\n'.join(stat_fmt) + '\\n'

      cmd = ['stat', '--printf' , printf_arg, path]
      quoted = shlex.join(cmd)
      rc, output = machine.execute(quoted)
      if rc != 0:
        return ['command `{0}` failed (exit code {1})'.format(quoted, rc)]

      errors = []
      for (line, check) in zip(output.split('\n'), checks):
        name, expected = check
        if not line == expected:
          errors.append('unexpected value for {0} on path {1}: expected {2}, got {3}'.format(name, path, expected, line))

      return errors

    def assert_directory(machine, path, **kwargs):
      return assert_stat(machine, path, 'directory', **kwargs)

    def assert_regular_file(machine, path, **kwargs):
      return assert_stat(machine, path, 'regular file', **kwargs)

    def assert_symbolic_link(machine, path, **kwargs):
      return assert_stat(machine, path, 'symbolic link', **kwargs)

    def run_checks():
      errors = []

      errors += assert_directory(machine, '/abc/foo', mode='0700', user='benny', group='benny')
      errors += assert_directory(machine, '/abc/foo/bar', mode='0700', user='benny', group='benny')
      errors += assert_directory(machine, '/abc/foo/bar/bazz', mode='0700', user='benny', group='benny')

      errors += assert_directory(machine, '/foo', mode='0700', user='benny', group='benny')
      errors += assert_directory(machine, '/foo/bar', mode='0700', user='benny', group='benny')
      errors += assert_directory(machine, '/foo/bar/bazz', mode='0700', user='benny', group='benny')

      errors += assert_directory(machine, '/abc/foo/bar/bazz/luhrmann', mode='0777', user='del', group='del')

      errors += assert_directory(machine, '/foo/bar/bazz/luhrmann', mode='0777', user='del', group='del')

      errors += assert_directory(machine, '/def/foo', mode='0755', user='alex', group='alex')
      errors += assert_directory(machine, '/def/foo/bar', mode='0755', user='alex', group='alex')
      errors += assert_directory(machine, '/def/foo/bar/bazz', mode='0755', user='alex', group='alex')
      errors += assert_directory(machine, '/def/foo/bar/bazz/quux', mode='0755', user='alex', group='alex')

      errors += assert_directory(machine, '/foo/bar/bazz/quux', mode='0755', user='alex', group='alex')

      errors += assert_directory(machine, '/abc/one/two/three', mode='0755', user='cat', group='cat')

      errors += assert_directory(machine, '/one/two/three', mode='0755', user='cat', group='cat')

      errors += assert_directory(machine, '/def/one/two/three/four', mode='0750', user='del', group='del')

      errors += assert_directory(machine, '/one/two/three/four', mode='0750', user='del', group='del')

      ${lib.optionalString persistenceSupportsRootOption ''
      # XXX yes, lines after the first have to be indented an extra two spaces
        errors += assert_directory(machine, '/here/one/two/three', mode='0755', user='cat', group='cat')
        errors += assert_directory(machine, '/there/one/two/three', mode='0755', user='cat', group='cat')
      ''}

      # These directories created by the core `config/users-groups.nix` module
      errors += assert_directory(machine, '/althome/me', mode='0700', user='me', group='me')
      errors += assert_directory(machine, '/home/you', mode='0700', user='you', group='you')

      # Permissions copied from `/althome/me`
      errors += assert_directory(machine, '/abc/althome/me', mode='0700', user='me', group='me')

      errors += assert_directory(machine, '/abc/althome/me/dotfiles', mode='0700', user='me', group='me')
      errors += assert_directory(machine, '/althome/me/dotfiles', mode='0700', user='me', group='me')

      # XXX note that the permissions on `/def/home/you` are copied from
      # `/home/def`, which already exists at the time `create-directories.bash`
      # runs.
      errors += assert_directory(machine, '/def/home/you', mode='0700', user='you', group='you')

      errors += assert_symbolic_link(machine, '/althome/me/.merc')
      errors += assert_symbolic_link(machine, '/home/you/.yourc')

      return errors

    start_all()

    machine.wait_for_file('/run/.persistence-setup-complete')

    with subtest('first run of activation script'):
      errors = run_checks()
      if len(errors) != 0:
        raise Exception('\n'.join(errors))

    with subtest('re-run activation script'):
      machine.succeed('/run/current-system/activate')

    with subtest('second run of activation script'):
      errors = run_checks()
      if len(errors) != 0:
        raise Exception('\n'.join(errors))
  '';
})
