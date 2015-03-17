# cassandra cluster deployment

# Settings ###############
image_id = 'cassandra' # Image slug for the cassandra one-click image
ssh_keys=[''] # ID of the ssh key to use.  To launch with passwords the two droplet create calls must be adjusted
token='' # Token Here
##########################


require 'droplet_kit'
require 'socket'
require 'timeout'

# method to check if a given port is open on a host.  used to check that cassandra has started on a remote host
def isopen(ip, port)
  begin
    Timeout::timeout(1) do
      begin
        s = TCPSocket.new(ip, port)
        s.close
        return true
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
        return false
      end
    end
  rescue Timeout::Error
  end

  return false
end

client = DropletKit::Client.new(access_token: token)
region = ''
droplet_size = ''
node_count = 0
cluster_name = ''
admin_user = ''
admin_pass = ''


puts "This script will create a Cassandra DB Cluster on DigitalOcean.  To begin we need to gather some details."

while region == '' do
puts "What region would you like to create your cluster in?"
puts "1. New York 3"
puts "2. London 1"
puts "3. Singapore 1"
puts "4. Amsterdam 2"
region_choice = gets.chomp
  case region_choice
  when "1"
    region = 'nyc3'
  when "2"
    region = 'lon1'
  when "3"
    region = 'sgp1'
  when "4"
    region = 'ams2'
  else
    region = ''
  end
end

while node_count == 0 do
  puts "How many nodes do you want to create for your cluster?"
  node_count = gets.chomp
end

while droplet_size == '' do
  puts "What size nodes do you want to create?"
  puts "1. 1GB - 1 Processor Core - 30GB SSD"
  puts "2. 2GB - 2 Processor Cores - 40GB SSD"
  puts "3. 4GB - 2 Processor Cores - 60GB SSD"
  puts "4. 8GB - 4 Processor Cores - 80GB SSD"
  puts "5. 16GB - 8 Processor Cores - 160GB SSD"
  droplet_size_choice = gets.chomp
  case droplet_size_choice
  when "1"
    droplet_size = '1gb'
  when "2"
    droplet_size = '2gb'
  when "3"
    droplet_size = '4gb'
  when "4"
    droplet_size = '8gb'
  when "5"
    droplet_size = '16gb'
  else
    droplet_size = ''
  end
  
end

while cluster_name == '' do
  puts "What name do you want to give your cluster?"
  cluster_name = gets.chomp
end

while admin_user == '' do
  puts "Enter a name for your Cassandra Superuser account (admin):"
  admin_user_input = gets.chomp
  if admin_user_input == ''
    admin_user = 'admin'
  else
    admin_user = admin_user_input
  end
  
end

while admin_pass == '' do
  puts "Enter a password for your Cassandra Superuser account"
  admin_pass_input = gets.chomp
  if admin_pass_input == ''
    admin_pass = ''
    puts "A valid password was not provided"
  else
    admin_pass = admin_pass_input
  end
  
end

puts "Creating a new cluster named #{cluster_name} in the #{region} region consisting of #{node_count} #{droplet_size} nodes..."



# Create first node (seed)
sitename = cluster_name+'0'
sitename.gsub!(/\s/,'-')

userdata = <<-EOM
#!/bin/bash
admin_user='#{admin_user}';
admin_password='#{admin_pass}';
tmp_pw=`openssl rand -base64 32`;
export IP_ADDRESS=$(curl -s http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address);
service cassandra stop;
rm -rf /var/lib/cassandra/*;
sed -i.bak "s/cluster\\_name\\:\\ 'Test Cluster'/cluster\\_name\\:\\ '#{cluster_name}'/g" /etc/cassandra/cassandra.yaml
sed -i.bak s/authenticator\\:\\ AllowAllAuthenticator/authenticator\\:\\ PasswordAuthenticator/g /etc/cassandra/cassandra.yaml;
sed -i.bak s/listen\\_address\\:\\ localhost/listen_address\\:\\ ${IP_ADDRESS}/g /etc/cassandra/cassandra.yaml;
sed -i.bak s/\\-\\ seeds\\:\\ \\"127.0.0.1\\"/\\-\\ seeds\\:\\ \\"${IP_ADDRESS}\\"/g /etc/cassandra/cassandra.yaml;
service cassandra start;
sleep 120;
# Add new superuser
cqlsh -u cassandra -p cassandra -e "CREATE USER ${admin_user} WITH PASSWORD '${admin_password}' SUPERUSER";
# Remove su from cassandra user
cqlsh -u ${admin_user} -p ${admin_password} -e "ALTER USER cassandra WITH PASSWORD '${tmp_pw}' NOSUPERUSER";

EOM

droplet = DropletKit::Droplet.new(name: sitename, region: region, size: droplet_size, image: image_id, user_data: userdata, ssh_keys: ssh_keys)
create = client.droplets.create(droplet)

droplets_created = 1;

createid = create.id.to_s

puts " "
print "Creating Seed Node..."
create_complete = 0


while create_complete != 1 do
  print "."
dobj = client.droplets.find(id: createid)

  if dobj.status == 'active'

    create_complete = 1
  else
    print "."
  end
sleep(5)  
end

print "\n\n"
puts "Create of Seed node complete"
# Get the IP address of our newly created seed node
droplets = client.droplets.all
drop_id = ''

droplets.each {|drop|
  
if drop.name == sitename
  drop_id = drop.id
  puts 'seed droplet id: '+drop_id.to_s
end
}
seed_drop = client.droplets.find(id: drop_id)

seed_address = seed_drop.networks.v4[0].ip_address

puts "SEED IP: "+seed_address
# Create additional nodes

# Now we will wait until the Cassandra service on our seed node is active and responding to requests.
puts "Waiting for Cassandra service to start on seed node..."
c_up = 0
while c_up != 1 do
  print "."
  if isopen(seed_address,7199)
    c_up = 1
  else
    c_up = 0
  end
  print "."
  sleep(5)
end


while droplets_created < node_count.to_i do
  puts "Deploying Node "+droplets_created.to_s
  sitename = cluster_name+droplets_created.to_s
  sitename.gsub!(/\s/,'-')

userdata = <<-EOM
#!/bin/bash
export SEED_ADDRESS='#{seed_address}';
export IP_ADDRESS=$(curl -s http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address);
service cassandra stop;
rm -rf /var/lib/cassandra/*;
sed -i.bak "s/cluster\\_name\\:\\ 'Test Cluster'/cluster\\_name\\:\\ '#{cluster_name}'/g" /etc/cassandra/cassandra.yaml
sed -i.bak s/authenticator\\:\\ AllowAllAuthenticator/authenticator\\:\\ PasswordAuthenticator/g /etc/cassandra/cassandra.yaml;
sed -i.bak s/listen\\_address\\:\\ localhost/listen_address\\:\\ ${IP_ADDRESS}/g /etc/cassandra/cassandra.yaml;
sed -i.bak s/\\-\\ seeds\\:\\ \\"127.0.0.1\\"/\\-\\ seeds\\:\\ \\"${SEED_ADDRESS}\\"/g /etc/cassandra/cassandra.yaml;
#sleep 240;
service cassandra start;

EOM
  
  droplet = DropletKit::Droplet.new(name: sitename, region: region, size: droplet_size, image: image_id, user_data: userdata, ssh_keys: ssh_keys)
  client.droplets.create(droplet)
  droplets_created += 1
end


