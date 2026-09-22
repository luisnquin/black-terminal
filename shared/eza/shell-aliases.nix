rec {
  ls = "eza --icons=auto";
  ll = "${ls} -l";
  la = "${ls} -a";
  lla = "${ls} -la";
  lt = "${ls} --tree";
  sls = "${ls} -Ta -I=.git";
}
