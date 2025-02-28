# Hadoop Docker Cluster Setup

This guide explains how to set up a Hadoop cluster using Docker containers. The setup includes one master node and multiple slave nodes. You can use this setup for distributed data processing and analytics.

## Prerequisites

- **Docker**: Ensure Docker is installed on your system.
- **Ubuntu Environment**: Use either a real Linux machine or Windows Subsystem for Linux (WSL).

## Steps to Set Up the Hadoop Cluster

### 1. Pull the Hadoop Docker Image

Pull the pre-built Hadoop Docker image from the provided link:

```bash
docker pull http:454.com/hadoop-image
```

### 2. Modify the `initialize.sh` File

The `initialize.sh` script initializes the Hadoop cluster. Modify the script to specify the total number of nodes (including the master node).

Update the `N` variable to the total number of nodes you want to run. For example, for 1 master and 3 slaves:

```bash
N=${1:-4}
```

### 3. Run the `initialize.sh` Script

Run the `initialize.sh` script in your Ubuntu environment (WSL or real Linux):

```bash
./initialize.sh
```

This script will:

- Create a Docker network for the Hadoop cluster.
- Start the master container (`hadoop-master`).
- Start the slave containers (`hadoop-slave1`, `hadoop-slave2`, etc.).
- Configure passwordless SSH between nodes.
- Set up Hadoop configuration files (`core-site.xml`, `hdfs-site.xml`, `yarn-site.xml`).
- Format the HDFS NameNode and start Hadoop services.

### 4. Access the Hadoop Web Interfaces

After the cluster is initialized, you can access the Hadoop web interfaces:

- **HDFS NameNode UI**: http://localhost:9870
- **YARN ResourceManager UI**: http://localhost:8088

### 5. Access Slave Containers

To access a slave container, use the following command:

```bash
docker exec -it hadoop-slave<i> /bin/bash
```

Replace `<i>` with the slave number (e.g., 1, 2, 3).

### 6. Build the Docker Image Yourself (Optional)

If you want to build the Hadoop Docker image yourself:

1. Download the Hadoop binary from the official website:

   - [Hadoop 3.3.0 Download](https://hadoop.apache.org/release/3.3.0.html)

2. Place the Hadoop binary (`hadoop-3.3.0.tar.gz`) in the same directory as the `Dockerfile`.

3. Build the Docker image:

```bash
docker build -t cmp25:hadoop -f Dockerfile .
```
