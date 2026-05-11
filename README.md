<h1 align="center"><b>MorfFlex: Handling Rich Morphology</b></h1>

<p align="center">
  <i><b>Jaroslava Hlaváčová, Marie Mikulová, Barbora Štěpánková, Milan Straka, Jan Hajič</b></i>
</p>

<p align="center">
  <i>
    Charles University<br>
    Faculty of Mathematics and Physics<br>
    Institute of Formal and Applied Linguistics
  </i>
</p>

---

This repository contains the script [generate.pl](generate.pl), which is used to
convert the MorfFlex CZ dictionary from the _source format_ to the _basic
format_ (i.e., flat form-lemma-tag triples), using the terminology from the
paper.

However, the source format of the MorfFlex CZ is not publicly available; we
therefore include only a very small sample of the required files in the
directory [example/](example/).

To run the script using the example data, use the following command:
```sh
perl generate.pl example/allowed_tags example/dist example/exp example/end example/dtypes example/dictionary ne nej nejne >dictionary.raw
```
