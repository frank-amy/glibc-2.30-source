/* Continuous integration of GNU with Hydra/Nix.
   Copyright (C) 2010, 2011  Ludovic Courtès <ludo@gnu.org>

   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <http://www.gnu.org/licenses/>.  */

{ nixpkgs ? ../../nixpkgs
, hurdSrc ? { outPath = /data/src/hurd/hurd; }
}:

let
  pkgs = import nixpkgs {};
  crossSystems = (import ../cross-systems.nix) { inherit pkgs; };

  meta = {
    description = "The GNU Hurd, GNU project's replacement for the Unix kernel";

    longDescription =
      '' The GNU Hurd is the GNU project's replacement for the Unix kernel.
         It is a collection of servers that run on the Mach microkernel to
         implement file systems, network protocols, file access control, and
         other features that are implemented by the Unix kernel or similar
         kernels (such as Linux).
      '';

    license = "GPLv2+";

    homepage = http://www.gnu.org/software/hurd/;

    maintainers = [ pkgs.stdenv.lib.maintainers.ludo ];
  };

  succeedOnFailure = true;
  keepBuildDirectory = true;

  jobs = {
    tarball =
      # "make dist" should work even non-natively and even without a
      # cross-compiler.  Doing so allows us to catch errors such as shipping
      # MIG-generated or compiled files in the distribution.
      pkgs.releaseTools.sourceTarball {
        name = "hurd-tarball";
        src = hurdSrc;
        configureFlags = "--build=i586-pc-gnu";  # cheat
        postConfigure =
          '' echo "removing \`-o root' from makefiles..."
             for mf in {utils,daemons}/Makefile
             do
               sed -i "$mf" -e's/-o root//g'
             done
          '';
        buildNativeInputs = [ pkgs.machHeaders pkgs.mig pkgs.texinfo ];
        buildInputs = [ pkgs.parted /* not the cross-GNU one */ pkgs.libuuid ];
        inherit meta succeedOnFailure keepBuildDirectory;
      };

    # Cross build from GNU/Linux.
    xbuild =
      { tarball ? jobs.tarball
      , parted ? (import ../parted/release.nix {}).xbuild_gnu {}
      }:

      let
        pkgs = import nixpkgs {
          system = "x86_64-linux";               # build platform
          crossSystem = crossSystems.i586_pc_gnu; # host platform
        };
      in
        (pkgs.releaseTools.nixBuild {
          name = "hurd";
          src = tarball;
          propagatedBuildNativeInputs = [ pkgs.machHeaders ];
          buildNativeInputs = [ pkgs.mig ];
          buildInputs = [ parted pkgs.libuuid ];
          inherit meta succeedOnFailure keepBuildDirectory;
        }).hostDrv;

    # Same without dependency on Parted.
    xbuild_without_parted =
      { tarball ? jobs.tarball
      }:

      let
        pkgs = import nixpkgs {
          system = "x86_64-linux";                # build platform
          crossSystem = crossSystems.i586_pc_gnu; # host platform
        };
      in
        (pkgs.releaseTools.nixBuild {
          name = "hurd";
          src = tarball;
          propagatedBuildNativeInputs = [ pkgs.machHeaders ];
          buildNativeInputs = [ pkgs.mig ];
          buildInputs = [ pkgs.libuuid ];
          configureFlags = [ "--without-parted" ];
          inherit meta;
        }).hostDrv;

    # Complete cross bootstrap of GNU from GNU/Linux.
    xbootstrap =
      { tarball ? jobs.tarball
      , glibcTarball }:

      let
        overrideHurdPackages = pkgs:

          # Override the `src' attribute of the Hurd packages.
          let
            override = pkgName: origPkg: latestPkg: clearPreConfigure:
              builtins.trace "overridding `${pkgName}'..."
              (pkgs.lib.overrideDerivation origPkg (origAttrs: {
                name = "${pkgName}-${latestPkg.version}";
                src = latestPkg;
                patches = [];

                # `sourceTarball' puts tarballs in $out/tarballs, so look there.
                preUnpack =
                  ''
                    if test -d "$src/tarballs"; then
                        src=$(ls -1 "$src/tarballs/"*.tar.bz2 "$src/tarballs/"*.tar.gz | sort | head -1)
                    fi
                  '';
              }
              //
              (if clearPreConfigure
               then { preConfigure = ":"; }
               else {})));
          in
            {
              # TODO: Handle `hurdLibpthreadCross', `machHeaders', etc. similarly.
              glibcCross = override "glibc" pkgs.glibcCross glibcTarball false;
              hurdCross = override "hurd" pkgs.hurdCross tarball true;
              hurdHeaders = override "hurd-headers" pkgs.hurdHeaders tarball true;
              hurdCrossIntermediate =
                 override "hurd-minimal" pkgs.hurdCrossIntermediate tarball true;
            };

        pkgs = import nixpkgs {
          system = "x86_64-linux";               # build platform
          crossSystem = crossSystems.i586_pc_gnu; # host platform
          config = { packageOverrides = overrideHurdPackages; };
        };
      in
        (pkgs.releaseTools.nixBuild {
          name = "hurd";
          src = tarball;
          propagatedBuildNativeInputs = [ pkgs.machHeaders ];
          buildNativeInputs = [ pkgs.mig ];
          inherit meta succeedOnFailure keepBuildDirectory;
        }).hostDrv;

    # A bare bones QEMU disk image with GNU/Hurd on partition 1.
    # FIXME: Currently hangs at "start ext2fs:".
    qemu_image =
      { build ? (jobs.xbuild_without_parted {})
      , mach ? ((import ../gnumach/release.nix {}).build {}) }:

      let
        size = 1024; fullName = "QEMU Disk Image of GNU/Hurd";
        pkgs = import nixpkgs {
          system = "x86_64-linux";               # build platform
          crossSystem = crossSystems.i586_pc_gnu; # host platform
        };
      in
        pkgs.vmTools.runInLinuxVM (pkgs.stdenv.mkDerivation {
          name = "hurd-qemu-image";
          preVM = pkgs.vmTools.createEmptyImage { inherit size fullName; };

          # Software cross-compiled for GNU to be installed.
          gnuDerivations =
            [ mach build
              pkgs.bash.hostDrv pkgs.coreutils.hostDrv
              pkgs.findutils.hostDrv pkgs.gnused.hostDrv
            ];

          # Command to build the disk image.
          buildCommand = let hd = "vda"; dollar = "\\\$"; in ''
            ${pkgs.parted}/sbin/parted /dev/${hd} \
               mklabel msdos mkpart primary ext2 1MiB 100MiB
            mknod /dev/${hd}1 b 254 1

            ${pkgs.e2fsprogs}/sbin/mke2fs -o hurd -F /dev/${hd}1
            mkdir /mnt
            ${pkgs.utillinux}/bin/mount -t ext2 /dev/${hd}1 /mnt

            mkdir -p /mnt/nix/store
            cp -rv "/nix/store/"*-gnu /mnt/nix/store

            mkdir /mnt/bin /mnt/dev
            ln -sv "${build}/hurd" /mnt/hurd
            ln -sv "${pkgs.bash.hostDrv}/bin/bash" /mnt/bin/sh

            mkdir -p /mnt/boot/grub
            ln -sv "${mach}/boot/gnumach" /mnt/boot
            cat > /mnt/boot/grub/grub.cfg <<EOF
set timeout=5
search.file /boot/gnumach

menuentry "GNU (wannabe NixOS GNU/Hurd)" {
  multiboot /boot/gnumach root=device:hd0s1
  module  /hurd/ext2fs.static ext2fs --readonly \
     --multiboot-command-line='${dollar}{kernel-command-line}' \
     --host-priv-port='${dollar}{host-port}' \
     --device-master-port='${dollar}{device-port}' \
     --exec-server-task='${dollar}{exec-task}' -T typed '${dollar}{root}' \
     '\$(task-create)' '\$(task-resume)'
  module ${pkgs.glibc.hostDrv}/lib/ld.so.1 exec /hurd/exec '\$(exec-task=task-create)'
}
EOF

            ${pkgs.grub2}/sbin/grub-install --no-floppy \
              --boot-directory /mnt/boot /dev/${hd}

            ${pkgs.utillinux}/bin/umount /mnt
          '';
        });
   };
in
  jobs
