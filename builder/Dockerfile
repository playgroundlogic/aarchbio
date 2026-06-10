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

USER root
# Install the primary pinned package plus any extras from bioconda (+ conda-forge
# for deps) into the base env. --platform is implied by the host arch on a native
# arm64 builder.
RUN micromamba install -y -n base \
        -c ${BIOCONDA_CHANNEL} -c conda-forge \
        "${PKG}=${PKG_VERSION}" ${EXTRA_PACKAGES} \
    && micromamba clean --all --yes

# Make the env's binaries the default PATH (matches biocontainers UX).
ENV PATH=/opt/conda/bin:$PATH

# Override misleading labels inherited from the micromamba base (its build date,
# git revision, and project URL would otherwise misrepresent this image's origin).
LABEL org.opencontainers.image.title="${PKG}" \
      org.opencontainers.image.version="${PKG_VERSION}" \
      org.opencontainers.image.source="${SOURCE_RECIPE}" \
      org.opencontainers.image.url="https://github.com/scttfrdmn/aarchbio" \
      org.opencontainers.image.revision="${BUILDER_GIT_SHA}" \
      org.opencontainers.image.vendor="Playground Logic" \
      org.opencontainers.image.description="Native arm64 rebuild of bioconda ${PKG}=${PKG_VERSION}. Unofficial community rebuild by Playground Logic; not affiliated with or endorsed by BioContainers or AWS." \
      io.aarchbio.bioconda-package="${PKG}" \
      io.aarchbio.bioconda-version="${PKG_VERSION}" \
      io.aarchbio.builder-git-sha="${BUILDER_GIT_SHA}" \
      io.aarchbio.build-platform="${BUILD_PLATFORM}" \
      io.aarchbio.publisher="Playground Logic"

# Default to a login-ish shell so `docker run <img> <tool> ...` works directly.
USER mambauser
