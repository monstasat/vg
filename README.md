-------------------------------------------------------------------------------
Vg - %%SYNOPSIS%%
     Release %%VERSION%%
-------------------------------------------------------------------------------

%%DESCRIPTION%%

Home page: %%HOMEPAGE%%
Contact: %%AUTHORS%%


Installation
------------

To install Vg you need at least : 

    OCaml %%OCAMLVERSION%% %%PPDEPS%%

If you have `findlib`, it can be installed by typing :

    ocaml setup.ml -configure
    ocaml setup.ml -build 
    ocaml setup.ml -install

If you don't, `%%NAME%%.mli` and `%%NAME%%.ml` contain everything, the
code, the documentation and the license. Install the dependencies and
use the sources the way you want. For example if you use `ocamlbuild`
you can issue the following commands from the root directory of your
project :

    ln -s /path/to/%%NAME%%-%%VERSION%%/src %%NAME%%
    echo "<%%NAME%%> : include" >> _tags


Documentation
-------------

The documentation and API reference is automatically generated by
`ocamldoc` from `%%NAME%%.mli`. For you convenience you can find a
generated version in the `doc` directory of the distribution.


Sample programs and images
--------------------------

A database of sample images can be found in the `db` directory.

Sample programs are located in the `test` directory of the
distribution. They can be built with:

    ocamlbuild test/tests.otarget

The resulting binaries are in `_build/test` :

- `rsvg.native`, renders images of the Vg image database to SVG files.
- `rpdf.native`, renders images of the Vg image database to PDF files.


