# Generic aarchbio builder.
#
# One Dockerfile for every tool: the tool + version are build args, so the same
# recipe scales from 1 image to 10,000. This mirrors how BioContainers itself
# works — an image is essentially `conda install <pkg>=<version>` in a base
# container — and rebuilds it natively for arm64.
#
# Base: micromamba (multi-arch; arm64 + amd64). On an arm64 host/builder this
# resolves the linux-aarch64 conda packages with NO emulation.
#
# Build via build.sh, which sets the args and stamps provenance labels (D6).
ARG MAMBA_VERSION=1.5.8
FROM mambaorg/micromamba:${MAMBA_VERSION}

# Tool identity — provided by build.sh.
ARG PKG
ARG PKG_VERSION
ARG BIOCONDA_CHANNEL=bioconda
# Which channel the package ACTUALLY came from. Almost always bioconda, but a few
# BioContainers tools are packaged in conda-forge instead (pigz has no bioconda
# recipe at all), and labelling those "rebuild of bioconda pigz" with a bioconda
# recipe URL that 404s would be a provenance lie. build.sh detects this.
ARG SOURCE_CHANNEL=bioconda

# Provenance (D6): who/what/where this image was built from. Stamped as OCI
# labels so any tag is traceable back to its bioconda source + this builder.
ARG SOURCE_RECIPE
ARG BUILDER_GIT_SHA=unknown
# TARGETPLATFORM is set automatically by buildx per target arch (e.g.
# linux/arm64, linux/amd64). For a noarch multi-arch build this records the
# correct platform on each variant rather than a single hardcoded value.
ARG TARGETPLATFORM
ARG BUILD_PLATFORM=${TARGETPLATFORM}

# Optional extra pinned packages for "mulled" images (e.g. Wave's
# kraken2_coreutils_pigz fuses kraken2+coreutils+pigz into one container). Space-
# separated "name=version" specs; empty for a normal single-tool image.
ARG EXTRA_PACKAGES=""

# Packages to RE-install in a second transaction, after the main one.
#
# For the rare upstream package that bundles its own copies of its dependencies'
# binaries and thereby overwrites them. humann 3.9 is the case this exists for: it
# is `noarch`, yet it ships bin/diamond and bin/bowtie2-* as x86-64 blobs. conda
# installs dependencies BEFORE the package that needs them, so the correct
# linux-aarch64 diamond and bowtie2 land first and humann then clobbers them --
# three packages end up owning the same paths. The image looks fine (python is
# aarch64, the tool imports) and dies the moment an aligner is executed.
#
# Re-installing the real packages afterwards restores the binaries their own
# recipes built, which is also exactly what humann's declared dependencies ask
# for -- that part changes no package's contents, only which transaction wrote the
# file last.
#
# It is not quite sufficient on its own. humann also bundles bowtie2's *-debug
# variants, which the real linux-aarch64 bowtie2 does not ship at all (9 bin
# entries, no debug builds), so re-installing cannot overwrite them and they
# survive as x86-64 files on PATH. So when REPAIR_PACKAGES is set we additionally
# DELETE any remaining foreign-architecture ELF in bin/ or libexec/. Narrow and
# deliberate: such a file is provided by no package built for this platform and
# cannot execute here, so removing it loses nothing and is the difference between
# a usable image and none. Both actions are recorded in a label.
ARG REPAIR_PACKAGES=""

# For legacy hashed mulled-v2 images the repo name is a sha1, not a package name,
# so the image title can't be ${PKG} (which is only the alphabetically-first
# ingredient). MULLED_SPECS records the full ingredient list, because that is the
# one thing a hashed name does NOT tell you — see builder/mulled.py.
ARG IMAGE_TITLE="${PKG}"
ARG MULLED_SPECS=""
# What this image is a rebuild OF, in prose. Split out so the legal disclaimer
# below stays single-sourced instead of being duplicated by every caller that
# needs a different subject (a mulled image is not "a rebuild of bioconda X=Y").
ARG IMAGE_SUBJECT="${SOURCE_CHANNEL} ${PKG}=${PKG_VERSION}"
# For a fused image no single ingredient's version describes the image, so callers
# override this with the mulled tag rather than let it read as one ingredient's
# version (it came out as pigz's "2.6" for a prodigal+pigz image).
ARG IMAGE_VERSION="${PKG_VERSION}"

USER root
# Install the primary pinned package plus any extras from bioconda (+ conda-forge
# for deps) into the base env. --platform is implied by the host arch on a native
# arm64 builder.
RUN micromamba install -y -n base \
        -c ${BIOCONDA_CHANNEL} -c conda-forge \
        "${PKG}=${PKG_VERSION}" ${EXTRA_PACKAGES} \
    && micromamba clean --all --yes

# Must be a SEPARATE transaction: within one transaction conda orders by
# dependency, so the clobbering package always wins regardless of argument order.
RUN if [ -n "${REPAIR_PACKAGES}" ]; then \
        echo "[repair] re-installing ${REPAIR_PACKAGES} so their own binaries win" && \
        micromamba install -y -n base -c ${BIOCONDA_CHANNEL} -c conda-forge \
            --force-reinstall ${REPAIR_PACKAGES} && \
        micromamba clean --all --yes && \
        echo "[repair] pruning any remaining foreign-architecture binaries" && \
        want=$( [ "$(uname -m)" = "aarch64" ] && echo 183 || echo 62 ) && \
        for f in /opt/conda/bin/* /opt/conda/libexec/*; do \
            [ -f "$f" ] || continue ; \
            [ "$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')" = "7f454c46" ] || continue ; \
            m=$(od -An -tu1 -j18 -N1 "$f" 2>/dev/null | tr -d ' ') ; \
            if [ "$m" != "$want" ]; then \
                echo "[repair]   removing $(basename "$f") (e_machine=$m, cannot execute here)" ; \
                rm -f "$f" ; \
            fi ; \
        done ; \
    fi

# Make the env's binaries the default PATH (matches biocontainers UX).
ENV PATH=/opt/conda/bin:$PATH

# Override misleading labels inherited from the micromamba base (its build date,
# git revision, and project URL would otherwise misrepresent this image's origin).
LABEL org.opencontainers.image.title="${IMAGE_TITLE}" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.source="${SOURCE_RECIPE}" \
      org.opencontainers.image.url="https://github.com/playgroundlogic/aarchbio" \
      org.opencontainers.image.revision="${BUILDER_GIT_SHA}" \
      org.opencontainers.image.vendor="Playground Logic" \
      org.opencontainers.image.description="Native arm64 rebuild of ${IMAGE_SUBJECT}. Unofficial community rebuild by Playground Logic; not affiliated with or endorsed by BioContainers or AWS." \
      io.aarchbio.mulled-specs="${MULLED_SPECS}" \
      io.aarchbio.extra-packages="${EXTRA_PACKAGES}" \
      io.aarchbio.repaired-packages="${REPAIR_PACKAGES}" \
      io.aarchbio.source-channel="${SOURCE_CHANNEL}" \
      io.aarchbio.source-package="${PKG}" \
      io.aarchbio.source-version="${PKG_VERSION}" \
      io.aarchbio.builder-git-sha="${BUILDER_GIT_SHA}" \
      io.aarchbio.build-platform="${BUILD_PLATFORM}" \
      io.aarchbio.publisher="Playground Logic"

# Default to a login-ish shell so `docker run <img> <tool> ...` works directly.
USER mambauser
