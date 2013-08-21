(*---------------------------------------------------------------------------
   Copyright 2013 Daniel C. Bünzli. All rights reserved.
   Distributed under the BSD3 license, see license at the end of the file.
   %%NAME%% release %%VERSION%%
  ---------------------------------------------------------------------------*)

(** Vg HTML canvas renderer.

    {b Note.} The even-odd area rule is supported according to the
    latest whatwg spec. This may not work in all browsers.

    {b References.} 
    {ul {- Rik Cabanier et al. {e {{:http://www.w3.org/TR/2dcontext/}HTML 
     Canvas 2D Context}}, 2012-12-17.}}

    {e Release %%VERSION%% - %%MAINTAINER%% } *)


(** {1 HTML canvas render targets} *)

val target : ?resolution:Gg.v2 -> Dom_html.canvasElement Js.t -> 
  [`Other] Vg.Vgr.target
(** [target resolution c] is a render target for rendering to the canvas 
    element [c]. 
    
    {ul 
    {- [resolution], specifies the rendering resolution in samples per 
       meters. If unspecified 11811 pixels per meters (300 ppi) is used in both 
       dimensions.}} *)


(** {1 Render warnings} 
    
    The following render warnings are reported:
    {ul
    {- [`Unsupported_cut ((`O o), i)], outline cuts can be performed only on 
       (possibly transformed) {!I.const}, {!I.axial} and {!I.radial} 
       primitive images.}
    {- [`Unsupported_glyph_cut (a, i)], glyph cuts can be performed only
       on bare {!I.const} primitive images and outline cuts are currently
       unsupported.}} *)

(** {1 Text rendering support} 

    Fonts use the CSS font selection mechanism. Make sure that the
    fonts you use are embedded (and {e loaded}) in your DOM via
    [\@font-face].

    The text rendering API of HTML canvas doesn't give control over
    glyph rendering. This means that the [advances] and glyph list
    arguments of {!Vg.I.cut_glyphs} are ignored and you will need to
    provide the [text] argument.

    At the moment the renderer also needs to work around a particular
    browser bug which means that glyphs cut are currently limited to
    non-outline area cuts in constant images.  *)

(** {1 Multiple images} 

    Rendering multiple images is supported. Each new render 
    clears the HTML canvas. *)

(*---------------------------------------------------------------------------
   Copyright 2013 Daniel C. Bünzli.
   All rights reserved.

   Redistribution and use in source and binary forms, with or without
   modification, are permitted provided that the following conditions
   are met:
     
   1. Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

   2. Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

   3. Neither the name of Daniel C. Bünzli nor the names of
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
   LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
   DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
   THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
   (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
   OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
  ---------------------------------------------------------------------------*)
