/* Continuous integration of GNU with Hydra/Nix.
   Copyright (C) 2011, 2012, 2013  Ludovic Courtès <ludo@gnu.org>
   Copyright (C) 2011  Rob Vermaas <rob.vermaas@gmail.com>

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

let
  meta = {
    description = "GNU Emacs, the extensible, customizable text editor";

    longDescription = ''
      GNU Emacs is an extensible, customizable text editor—and more.  At its
      core is an interpreter for Emacs Lisp, a dialect of the Lisp
      programming language with extensions to support text editing.

      The features of GNU Emacs include: content-sensitive editing modes,
      including syntax coloring, for a wide variety of file types including
      plain text, source code, and HTML; complete built-in documentation,
      including a tutorial for new users; full Unicode support for nearly all
      human languages and their scripts; highly customizable, using Emacs
      Lisp code or a graphical interface; a large number of extensions that
      add other functionality, including a project planner, mail and news
      reader, debugger interface, calendar, and more.  Many of these
      extensions are distributed with GNU Emacs; others are available
      separately.
    '';

    homepage = http://www.gnu.org/software/emacs/;
    license = "GPLv3+";

    maintainers = [ "emacs-buildstatus@gnu.org" ];
  };

  nixpkgs = <nixpkgs>;
  emacs = <emacs>;

  # Return the list of dependencies.
  buildInputsFrom = pkgs: with pkgs;
    [ texinfo ncurses pkgconfig x11 ]
    ++ (with xorg; [ libXft libXpm ])

    # Optional dependencies that fail to build on non-GNU platforms.
    ++ (stdenv.lib.optionals stdenv.isLinux
         [ gtk3-x11 librsvg acl dbus gnutls gpm libselinux imagemagick
           libpng libjpeg libungif libtiff libxml2 harfbuzz ])

    # Fallback for non-GNU systems.
    ++ (stdenv.lib.optional (!stdenv.isLinux) xlibs.libXaw);

in
  import ../gnu-jobs.nix {
    name = "emacs";
    src  = emacs;
    inherit nixpkgs meta;
    useLatestGnulib = false;

    systems = [ "x86_64-linux" "x86_64-darwin" "i686-linux"];

    customEnv = rec {

      tarball = pkgs: {
	# FIXME Move --enable-check-lisp-object-type here from coverage?
	configureFlags = "--without-all --without-x";
	buildInputs = with pkgs; [ texinfo ncurses pkgconfig perl git ];

        # patches = [ ./bug11251.patch ];
        # enableParallelBuilding = true;

	autoconfPhase = ''
	  for i in Makefile.in ./src/Makefile.in ./lib-src/Makefile.in ./leim/Makefile.in; do
	    substituteInPlace $i --replace /bin/pwd pwd
	  done

	  ./autogen.sh
	'';

	distPhase = ''
	  make info all
	  ./make-dist --tar --tests --no-update --no-check
	  mkdir -p $out/tarballs
	  cp -pvd *.tar.gz $out/tarballs
	'';
      } ;

      build = pkgs: {
	buildInputs = buildInputsFrom pkgs;
	doCheck = false;
	configureFlags =
	  with pkgs;
	  [ # Make sure `configure' doesn't pick /usr/lib on impure platforms
	    # such as Darwin.
	    "--x-libraries=${xlibs.libX11}/lib"
	    "--x-includes=${xlibs.libX11}/include"
	  ]
	  ++
	  (if stdenv.isLinux then
	     [ "" ]
	   else
	     [ "--with-xpm=no" "--with-jpeg=no" "--with-png=no"
	       "--with-gif=no" "--with-tiff=no"
	     ])
	  ++
	  (if stdenv.isDarwin then
	     [ "--without-ns" "--with-gnutls=no" ]
	   else
	     [ "" ]);

	## http://github.com/NixOS/nixpkgs/blob/master/pkgs/stdenv/generic/setup.sh
	## Could we use the postConfigure hook instead of this?
	configurePhase = ''
	  configureFlags="--prefix=$prefix $configureFlags"
	  echo "configure flags: $configureFlags"
	  if ! ./configure $configureFlags; then
	    cat config.log
	    false
	  fi
	'';
      };

      coverage = pkgs: {
	LOCALE_ARCHIVE = "${pkgs.glibcLocales}/lib/locale/locale-archive";
	buildInputs = with pkgs; [ gcc48 gnused bazaar perl python gnupg git mercurial lcms2 jansson ruby gmp m17n_lib libotf ] ++ buildInputsFrom pkgs;
	doCheck = true;
	configureFlags = "--enable-profiling --enable-check-lisp-object-type --with-modules CC=${pkgs.gcc48}/bin/gcc" ;
	checkPhase = ''
          make check-expensive EMACS_HYDRA_CI=1 TEST_BACKTRACE_LINE_LENGTH=150 TEST_LOAD_EL=no SUMMARIZE_TESTS=25
          mkdir -p "$out/nix-support"
          find test -name '*.log' > test.tmp
          if test -s test.tmp; then
            emacsver=$(./src/emacs --version | sed -n 's/^GNU Emacs \([0-9\.]*\)\.[0-9]$/\1/p')
            logdir="$out/share/emacs/$emacsver"
            mkdir -p "$logdir"
            tar -c -f "$logdir/test-logs.tar" -T test.tmp
            echo "file test-logs $logdir/test-logs.tar" >> "$out/nix-support/hydra-build-products"
          fi
          rm -f test.tmp
	'';
      };

      build_doc = pkgs: {
        buildInputs = (buildInputsFrom pkgs)
          ++ [ pkgs.texinfo pkgs.texlive.combined.scheme-basic ];
	doCheck = false;
        buildPhase = "make docs";
        installPhase = ''
          make install-doc
          mkdir -p "$out/nix-support"
          echo "doc manual $out/share/doc/emacs/emacs.html index.html" >> "$out/nix-support/hydra-build-products"
          echo "doc-pdf manual $out/share/doc/emacs/emacs.pdf" >> "$out/nix-support/hydra-build-products"
       '';
      };
    };
  }
