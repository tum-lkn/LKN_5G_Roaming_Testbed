ARG dist=ubuntu
ARG tag=22.04
FROM ${dist}:${tag}

# Prevent interactive prompts (IMPORTANT)
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Set timezone properly so tzdata does not prompt
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Install dependencies for Open5GS
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
        python3-pip \
        python3-setuptools \
        python3-wheel \
        ninja-build \
        build-essential \
        flex \
        bison \
        git \
        cmake \
        meson \
        iproute2 \
        ca-certificates \
        netbase \
        pkg-config \
        gnupg \
        curl \
        net-tools \
        tshark && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Add MongoDB repository and import the public key
RUN curl -fsSL https://pgp.mongodb.com/server-6.0.asc | \
    gpg -o /usr/share/keyrings/mongodb-server-6.0.gpg --dearmor && \
    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-6.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/6.0 multiverse" \
    | tee /etc/apt/sources.list.d/mongodb-org-6.0.list

# Install MongoDB and nano - this is where tzdata would hang
RUN apt-get update && apt-get install -y mongodb-org nano

# Create necessary directories for MongoDB
RUN mkdir -p /data/db /var/log/mongodb
WORKDIR /open5gs

# Copy scripts
COPY ./start_services.sh /open5gs/start_services.sh
COPY ./open5gs-dbctl.sh /open5gs/open5gs-dbctl.sh

RUN chmod +x /open5gs/start_services.sh
RUN chmod +x /open5gs/open5gs-dbctl.sh

CMD ["/open5gs/start_services.sh"]
