#!/bin/sh

set -e
set -x

# install adduser and add the airflow user
dnf update -y
dnf install -y shadow-utils
adduser -s /bin/bash -d "${AIRFLOW_USER_HOME}" airflow
dnf install -y sudo

echo 'airflow ALL=(ALL)NOPASSWD:ALL' | sudo EDITOR='tee -a' visudo

dnf erase openssl-devel -y
dnf install openssl openssl-devel libffi-devel sqlite-devel bzip2-devel wget tar xz -y
# Install python optional standard libary module dependencies
dnf install ncurses-devel gdbm-devel readline-devel xz-libs xz-devel uuid-devel libuuid-devel -y
dnf install glibc -y

# install system dependency to enable the installation of most Airflow extras
dnf install -y gcc gcc-c++ cyrus-sasl-devel python3-devel python3-wheel make

# Python 3.11 install
sudo mkdir python_install
python_file=Python-$PYTHON_VERSION
python_tar=$python_file.tar
python_xz=$python_tar.xz
sudo mkdir python_source
wget "https://www.python.org/ftp/python/$PYTHON_VERSION/$python_xz" -P /python_source
cp /python_source/$python_xz /python_install/$python_xz
unxz ./python_install/$python_xz
tar -xf ./python_install/$python_tar -C ./python_install

dnf install -y dnf-plugins-core
dnf builddep -y python3

pushd /python_install/$python_file
./configure
make install -j $(nproc) # use -j to set the cores for the build
popd

# Upgrade pip — modern pip is required for correct dependency resolution
pip3 install --upgrade pip

# openjdk is required for JDBC to work with Airflow
dnf install -y java-17-amazon-corretto

# Installing mariadb-devel dependency for apache-airflow-providers-mysql.
sudo mkdir mariadb_rpm
sudo chown airflow /mariadb_rpm

if [[ $(uname -p) == "aarch64" ]]; then
  wget https://mirror.mariadb.org/yum/11.4/fedora38-aarch64/rpms/MariaDB-common-11.4.2-1.fc38.$(uname -p).rpm -P /mariadb_rpm
  wget https://mirror.mariadb.org/yum/11.4/fedora38-aarch64/rpms/MariaDB-shared-11.4.2-1.fc38.$(uname -p).rpm -P /mariadb_rpm
  wget https://mirror.mariadb.org/yum/11.4/fedora38-aarch64/rpms/MariaDB-devel-11.4.2-1.fc38.$(uname -p).rpm -P /mariadb_rpm
else
  wget https://mirror.mariadb.org/yum/11.4/fedora38-amd64/rpms/MariaDB-common-11.4.2-1.fc38.$(uname -p).rpm -P /mariadb_rpm
  wget https://mirror.mariadb.org/yum/11.4/fedora38-amd64/rpms/MariaDB-shared-11.4.2-1.fc38.$(uname -p).rpm -P /mariadb_rpm
  wget https://mirror.mariadb.org/yum/11.4/fedora38-amd64/rpms/MariaDB-devel-11.4.2-1.fc38.$(uname -p).rpm -P /mariadb_rpm
fi

# install mariadb_devel and its dependencies
sudo rpm -ivh /mariadb_rpm/*

# Install system libraries needed for Python packages with native extensions
dnf install -y libxml2-devel libxslt-devel libcurl-devel postgresql-devel unixODBC-devel

# ============================================================================
# Python package installation
#
# All pip installs use --constraint to prevent dependency version conflicts.
# The constraints file pins every transitive dependency to a known-good version
# that is compatible with this Airflow release.
# ============================================================================

CONSTRAINT_FILE="/constraints.txt"

sudo -u airflow pip3 install $PIP_OPTION --constraint $CONSTRAINT_FILE wheel
sudo -u airflow pip3 install $PIP_OPTION --constraint $CONSTRAINT_FILE \
    apache-airflow[celery,statsd"${AIRFLOW_DEPS:+,}${AIRFLOW_DEPS}"]=="${AIRFLOW_VERSION}"

# install celery[sqs] and its dependencies
export PYCURL_SSL_LIBRARY=openssl11
sudo -u airflow pip3 install $PIP_OPTION --constraint $CONSTRAINT_FILE --compile pycurl
sudo -u airflow pip3 install $PIP_OPTION --constraint $CONSTRAINT_FILE celery[sqs]

# install postgres Python driver
sudo -u airflow pip3 install $PIP_OPTION --constraint $CONSTRAINT_FILE psycopg2

# install additional python dependencies
if [ -n "${PYTHON_DEPS}" ]; then
    sudo -u airflow pip3 install $PIP_OPTION --constraint $CONSTRAINT_FILE "${PYTHON_DEPS}"
fi

# install MWAA base providers
MWAA_BASE_PROVIDERS_FILE=/mwaa-base-providers-requirements.txt
echo "Installing providers supported for airflow version ${AIRFLOW_VERSION}"
sudo -u airflow pip3 install $PIP_OPTION --constraint $CONSTRAINT_FILE -r $MWAA_BASE_PROVIDERS_FILE

# ============================================================================
# Verify critical dependency versions are correct.
# pydantic_core requires typing_extensions>=4.14.1 for the Sentinel class.
# If an unconstrained transitive install somehow downgraded it, fix it now.
# ============================================================================
INSTALLED_TE_VERSION=$(sudo -u airflow pip3 show typing_extensions 2>/dev/null | grep '^Version:' | awk '{print $2}')
echo "typing_extensions version after install: ${INSTALLED_TE_VERSION}"

# Compare versions — we need at least 4.14.1
REQUIRED_TE_VERSION="4.14.1"
if [ "$(printf '%s\n' "$REQUIRED_TE_VERSION" "$INSTALLED_TE_VERSION" | sort -V | head -n1)" != "$REQUIRED_TE_VERSION" ]; then
    echo "ERROR: typing_extensions ${INSTALLED_TE_VERSION} is too old (need >= ${REQUIRED_TE_VERSION}). Upgrading..."
    sudo -u airflow pip3 install $PIP_OPTION "typing_extensions>=4.14.1"
fi

# Smoke test: verify pydantic can actually import (catches typing_extensions issues)
sudo -u airflow python3 -c "from pydantic import BaseModel; print('pydantic import OK')"

# jq is used to parse json
dnf install -y jq

# nc is used to check DB connectivity
dnf install -y nc

# install archiving packages
dnf install -y zip unzip bzip2 gzip # tar

# install awscli v2
zip_file="awscliv2.zip"
cd /tmp
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o $zip_file
unzip $zip_file
./aws/install
rm $zip_file
rm -rf ./aws
cd -  # Return to previous directory

dnf clean all
