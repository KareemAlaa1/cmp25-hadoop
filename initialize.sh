#!/bin/bash


#!/bin/bash

# the default node number is 3
N=${1:-5}

sudo docker network create --driver=bridge hadoop

# start hadoop master container
sudo docker rm -f hadoop-master &> /dev/null
echo "start hadoop-master container..."
sudo docker run -itd \
                --net=hadoop \
                -p 50070:50070 \
                -p 8088:8088 \
                -p 9870:9870 \
                -p 9864:9864 \
                --name hadoop-master \
                --hostname hadoop-master \
                elbadawy:hadoop bash&> /dev/null


# start hadoop slave container
i=1
while [ $i -lt $N ]
do
	sudo docker rm -f hadoop-slave$i &> /dev/null
	echo "start hadoop-slave$i container..."
	sudo docker run -itd \
	                --net=hadoop \
	                --name hadoop-slave$i \
	                --hostname hadoop-slave$i \
	                elbadawy:hadoop bash&> /dev/null
	i=$(( $i + 1 ))
done 



# Variables
MASTER_USER="hdfs"                  # User on the master node
SLAVE_USER="hdfs"                   # User on the slave nodes
MASTER_HOST="hadoop-master"         # Hostname of the master node
n=$(( $i - 1 ))                               # Number of slave nodes (change this value as needed)
SSH_KEY_PATH="/home/$MASTER_USER/.ssh/id_rsa"  # Path to the SSH key
HADOOP_HOME="/usr/local/hadoop"     # Hadoop installation directory

# Generate slave hostnames dynamically
SLAVE_HOSTS=()
for ((i=1; i<=n; i++)); do
    SLAVE_HOSTS+=("hadoop-slave$i")
done

# Step 1: Generate SSH key pair on the master node and capture the public key
echo "Generating or retrieving SSH key pair from master node..."
MASTER_PUB_KEY=$(docker exec -it "$MASTER_HOST" /bin/bash -c "
    if [ ! -f ~/.ssh/id_rsa ]; then
        mkdir -p ~/.ssh
        ssh-keygen -t rsa -P '' -f ~/.ssh/id_rsa
        cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
        chmod 700 ~/.ssh
        chmod 600 ~/.ssh/authorized_keys
        sudo service ssh restart
        sudo service ssh start
    fi
    cat ~/.ssh/id_rsa.pub
")

# Check if we successfully retrieved the public key
if [ -z "$MASTER_PUB_KEY" ]; then
    echo "Failed to retrieve master's public key. Exiting."
    exit 1
fi

echo "Master's public key: $MASTER_PUB_KEY"

# Step 2: Copy the master node's public key to all slave nodes
echo "Copying master node's public key to all slave nodes..."
for SLAVE_HOST in "${SLAVE_HOSTS[@]}"; do
    echo "Configuring $SLAVE_HOST..."
    docker exec -it "$SLAVE_HOST" /bin/bash -c "
        mkdir -p ~/.ssh
        chmod 700 ~/.ssh
        
        # Generate slave's own key if it doesn't exist
        if [ ! -f ~/.ssh/id_rsa ]; then
            ssh-keygen -t rsa -P '' -f ~/.ssh/id_rsa
            cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
        fi
        
        # Add master's key to authorized_keys
        echo '$MASTER_PUB_KEY' >> ~/.ssh/authorized_keys
        sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        
        # Ensure SSH service is running
        sudo service ssh restart
        sudo service ssh start
    "
done

# Step 3: Collect public keys from all slave nodes and add them to the master node
echo "Collecting public keys from all slave nodes and adding them to the master node..."
for SLAVE_HOST in "${SLAVE_HOSTS[@]}"; do
    echo "Fetching public key from $SLAVE_HOST..."
    SLAVE_PUB_KEY=$(docker exec -it "$SLAVE_HOST" /bin/bash -c "cat ~/.ssh/id_rsa.pub")
    docker exec -it "$MASTER_HOST" /bin/bash -c "echo '$SLAVE_PUB_KEY' >> ~/.ssh/authorized_keys"
done

# Step 4: Ensure proper permissions on the master node
echo "Setting proper permissions on the master node..."
docker exec -it "$MASTER_HOST" /bin/bash -c "
    chmod 700 ~/.ssh;
    chmod 600 ~/.ssh/authorized_keys;
    exit"

# Step 5: Restart SSH service on the master node
echo "Restarting SSH service on the master node..."
docker exec -it "$MASTER_HOST" /bin/bash -c "
    sudo service ssh restart;
    sudo service ssh start;
    exit"

# Step 6: Add slave IPs to $HADOOP_HOME/etc/hadoop/workers on the master node
echo "Adding slave IPs to $HADOOP_HOME/etc/hadoop/workers on the master node..."
for SLAVE_HOST in "${SLAVE_HOSTS[@]}"; do
    SLAVE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$SLAVE_HOST")
    docker exec -it "$MASTER_HOST" /bin/bash -c "echo '$SLAVE_IP' | sudo tee -a $HADOOP_HOME/etc/hadoop/workers > /dev/null"
done

echo "Passwordless SSH setup and workers file configuration completed successfully!"

# Step 7: Update core-site.xml with the master node's IP address
echo "Updating core-site.xml with the master node's IP address..."
MASTER_IP=$(docker exec -i "$MASTER_HOST" bash -c "hostname -I | awk '{print \$1}'")
echo "Master node IP: $MASTER_IP"

# Update core-site.xml on the master node
docker exec -i "$MASTER_HOST" bash -c "
    # Create a temporary file with updated content
    sudo cat $HADOOP_HOME/etc/hadoop/core-site.xml | 
    sed '/<name>fs\.defaultFS<\/name>/{n;s|<value>.*</value>|<value>hdfs://$MASTER_IP:9000</value>|}' > /tmp/core-site.xml.new
    
    # Copy the updated file back with elevated permissions using sudo tee.
    sudo tee $HADOOP_HOME/etc/hadoop/core-site.xml < /tmp/core-site.xml.new
"

# Update core-site.xml on all slave nodes
for SLAVE_HOST in "${SLAVE_HOSTS[@]}"; do
    echo "Updating core-site.xml on $SLAVE_HOST..."
    docker exec -i "$SLAVE_HOST" bash -c "
        # Create a temporary file with updated content
        sudo cat $HADOOP_HOME/etc/hadoop/core-site.xml | 
        sed '/<name>fs\.defaultFS<\/name>/{n;s|<value>.*</value>|<value>hdfs://$MASTER_IP:9000</value>|}' > /tmp/core-site.xml.new
        
        # Copy the updated file back with elevated permissions using sudo tee.
        sudo tee $HADOOP_HOME/etc/hadoop/core-site.xml < /tmp/core-site.xml.new
    "
done


# Step 8: Update yarn-site.xml with the provided configuration
echo "Updating yarn-site.xml with the provided configuration..."

# Define the YARN configuration

HDFS_SITE_CONFIG="<configuration>
  <property>
   <name>dfs.replication</name>
   <value>1</value>
  </property>
  <property>
   <name>dfs.namenode.name.dir</name>
   <value>file:/usr/local/hadoop_space/hdfs/namenode</value>
  </property>
  <property>
   <name>dfs.datanode.data.dir</name>
   <value>file:/usr/local/hadoop_space/hdfs/datanode</value>
  </property>  <property>
   <name>dfs.namenode.rpc-address</name>
   <value>$MASTER_IP:9000</value>
  </property>  <property>
   <name>dfs.namenode.http-address</name>
   <value>$MASTER_IP:50070</value>
  </property>  <property>
   <name>dfs.datanode.address</name>
   <value>0.0.0.0:9866</value>
  </property>  <property>
   <name>dfs.datanode.http-address</name>
   <value>0.0.0.0:9864</value>
  </property>

</configuration>"
YARN_CONFIG="<configuration>
    <!-- ResourceManager hostname -->
    <property>
        <name>yarn.resourcemanager.hostname</name>
        <value>$MASTER_IP</value>
    </property>

    <!-- ResourceManager address -->
    <property>
        <name>yarn.resourcemanager.address</name>
        <value>$MASTER_IP:8032</value>
    </property>

    <!-- ResourceManager Scheduler address -->
    <property>
        <name>yarn.resourcemanager.scheduler.address</name>
        <value>$MASTER_IP:8030</value>
    </property>

    <!-- NodeManagers should talk to this -->
    <property>
        <name>yarn.resourcemanager.resource-tracker.address</name>
        <value>$MASTER_IP:8031</value>
    </property>

    <!-- NodeManagers register here -->
    <property>
        <name>yarn.resourcemanager.admin.address</name>
        <value>$MASTER_IP:8033</value>
    </property>

    <!-- Services required for running MapReduce jobs -->
    <property>
        <name>yarn.nodemanager.aux-services</name>
        <value>mapreduce_shuffle</value>
    </property>

    <!-- Enable shuffle service for MapReduce -->
    <property>
        <name>yarn.nodemanager.aux-services.mapreduce.shuffle.class</name>
        <value>org.apache.hadoop.mapred.ShuffleHandler</value>
    </property>

    <!-- Memory allocated for NodeManager -->
    <property>
        <name>yarn.nodemanager.resource.memory-mb</name>
        <value>8192</value>
    </property>

    <!-- CPU cores allocated for NodeManager -->
    <property>
        <name>yarn.nodemanager.resource.cpu-vcores</name>
        <value>8</value>
    </property>

    <!-- Where logs are stored -->
    <property>
        <name>yarn.nodemanager.log-dirs</name>
        <value>/var/log/hadoop-yarn</value>
    </property>

    <!-- Container logs -->
    <property>
        <name>yarn.nodemanager.remote-app-log-dir</name>
        <value>/var/log/hadoop-yarn/apps</value>
    </property>
</configuration>"

# Update yarn-site.xml on the master node
docker exec -i "$MASTER_HOST" bash -c "
    # Create a temporary file with updated content
    echo '$YARN_CONFIG' > /tmp/yarn-site.xml.new
    
    # Copy the updated file back with elevated permissions using sudo tee.
    sudo tee $HADOOP_HOME/etc/hadoop/yarn-site.xml < /tmp/yarn-site.xml.new

    echo '$HDFS_SITE_CONFIG' > /tmp/hdfs-site.xml.new
    
    sudo tee $HADOOP_HOME/etc/hadoop/hdfs-site.xml < /tmp/hdfs-site.xml.new

    sudo mkdir -p /var/log/hadoop-yarn
    sudo chown hdfs /var/log/hadoop-yarn
    sudo chmod 775 /var/log/hadoop-yarn
"

# Update yarn-site.xml on all slave nodes
for SLAVE_HOST in "${SLAVE_HOSTS[@]}"; do
    echo "Updating yarn-site.xml on $SLAVE_HOST..."
    docker exec -i "$SLAVE_HOST" bash -c "
        # Create a temporary file with updated content
        echo '$YARN_CONFIG' > /tmp/yarn-site.xml.new
        
        # Copy the updated file back with elevated permissions using sudo tee.
        sudo tee $HADOOP_HOME/etc/hadoop/yarn-site.xml < /tmp/yarn-site.xml.new

        echo '$HDFS_SITE_CONFIG' > /tmp/hdfs-site.xml.new
        
        sudo tee $HADOOP_HOME/etc/hadoop/hdfs-site.xml < /tmp/hdfs-site.xml.new

        sudo mkdir -p /var/log/hadoop-yarn
        sudo chown hdfs /var/log/hadoop-yarn
        sudo chmod 775 /var/log/hadoop-yarn

    "
done


# get into hadoop master container
docker exec -it "$MASTER_HOST" /bin/bash -c "
    hdfs namenode -format;
    start-all.sh;
    start-yarn.sh;
    "
sudo docker exec -it hadoop-master bash