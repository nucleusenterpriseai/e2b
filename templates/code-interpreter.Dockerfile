# E2B Code Interpreter Template
# Ubuntu 22.04 with Python data science stack and Jupyter kernel
#
# Optimized for running Python code snippets, data analysis, and
# generating visualizations. Used by the E2B Code Interpreter SDK.

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# Install system packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    wget \
    git \
    sudo \
    ca-certificates \
    gnupg \
    # Python 3
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    # Build deps for Python packages
    build-essential \
    gfortran \
    libopenblas-dev \
    liblapack-dev \
    pkg-config \
    # Image rendering support (matplotlib backend)
    libfreetype6-dev \
    libpng-dev \
    # Font support for plots
    fonts-liberation \
    fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

# Install Python data science stack
RUN pip3 install --no-cache-dir \
    # Core data science
    numpy \
    pandas \
    scipy \
    # Visualization
    matplotlib \
    seaborn \
    plotly \
    # Jupyter kernel for code execution
    jupyter \
    ipykernel \
    # HTTP and utilities
    requests \
    httpx \
    beautifulsoup4 \
    lxml \
    # File handling
    openpyxl \
    pyyaml \
    toml \
    # Misc utilities
    tqdm \
    python-dateutil \
    pytz \
    Pillow

# Install ipykernel for the default Python 3 kernel
RUN python3 -m ipykernel install --name python3 --display-name "Python 3"

# Verify key packages
RUN python3 -c "import numpy; import pandas; import matplotlib; import scipy; print('All packages imported successfully')"

# Create default user with passwordless sudo
RUN useradd -m -s /bin/bash user \
    && echo "user ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER user
WORKDIR /home/user
