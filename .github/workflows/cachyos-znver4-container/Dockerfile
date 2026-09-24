# Staged GitHub Actions build container for the CachyOS znver4 branch.
FROM cachyos/docker-makepkg-znver4:latest

USER root
WORKDIR /home/notroot

RUN sed -i 's|^PKGDEST=.*|PKGDEST=/home/notroot|' /etc/makepkg.conf

COPY PKGBUILD /home/notroot/PKGBUILD
RUN chown notroot:notroot /home/notroot/PKGBUILD && \
    sudo -u notroot bash -lc 'cd /home/notroot && makepkg --nobuild --noextract --syncdeps --noconfirm'

COPY .github/workflows/cachyos-znver4-container/run.sh /home/notroot/run.sh

COPY *.src.tar.gz /home/notroot/
RUN chown -R notroot:notroot /home/notroot && \
    sudo -u notroot bash -lc 'cd /home/notroot && tar xf ./*.src.tar.gz --strip 1 && rm -f ./*.src.tar.gz' && \
    date +"%s" > /etc/buildtime

USER notroot
WORKDIR /home/notroot
ENTRYPOINT ["/bin/bash", "/home/notroot/run.sh"]
