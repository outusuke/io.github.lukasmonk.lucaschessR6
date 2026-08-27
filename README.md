Flatpak build for lucaschessR6


flatpak run org.flatpak.Builder \
  --force-clean \
  --user \
  --install \
  --install-deps-from=flathub \
  build-dir \
  io.github.lukasmonk.lucaschessR6.yml
  
  flatpak run io.github.lukasmonk.lucaschessR6
