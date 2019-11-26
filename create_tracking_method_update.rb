#!/usr/bin/ruby
require 'csv'
require 'ipaddr'
require 'digest'
require 'fileutils'
# Copyright 2019 Daniel Rearick
# Distributed under the terms of the GNU General Public License (GPL) v3.0

# Usage: ./create_tracking_method_update.rb QUALYS_NAME_TRACKING_FILE QUALYS_IP_TRACKING_FILE DHCP_ADDRESS_POOL_FILE

### Set script parameters with the arguments passed at the command line ###
# File containing the current state of Qualys host assets tracked by DNS name
QUALYS_NAME_TRACKING_FILE = ARGV[0]
# File containing the current state of Qualys host assets tracked by IP address
QUALYS_IP_TRACKING_FILE = ARGV[1]
# File containing the current state of the environments DHCP address pool
DHCP_ADDRESS_POOL_FILE = ARGV[2]

### Declare other constant parameters ###
# .gitignore file contents
GITIGNORE = [
  "DL_host_assets*.csv",
  "dhcp_address_pool_*.txt",
  "track_by_dns_name.txt",
  "track_by_ip_address.txt",
  "add_to_subscription.txt"
]
# .gitignore sha512 hash
GITIGNORE_DIGEST = "7336e7544702c1ab0b3e2dab360022e7094e7d6ba42d1f24859eae8fbfabf2ab79b3db279df22d9f397c1d4f154bc03ac5c7164e7a58e5419ec633ce59be6ded"
# File for diff tracking
NAME_TRACKING_FILE = "track_by_name.txt"
# File to check name tracking adds against current IP tracking to identify IPs missing from the subscription
SUBSCRIPTION_ADD_CHECK_FILE = "subscription_add_check.txt"
# File to output name tracking adds
NAME_TRACKING_ADDS_FILE = "out_files/track_by_dns_name.txt"
# File to output name tracking deletes
NAME_TRACKING_DELETES_FILE = "out_files/track_by_ip_address.txt"
# File to output Qualys subscription adds
SUBSCRIPTION_ADDS_FILE = "out_files/add_to_subscription.txt"
# Qualys name tracked host asset list commit message substring
QUALYS_NAME_TRACKING_COMMIT = "the current assets tracked by DNS Name in Qualys"
# Qualys IP tracked host asset list commit message substring
QUALYS_IP_TRACKING_COMMIT = "the current assets tracked by IP Address in Qualys"
# DHCP address pool list commit message substring
DHCP_POOL_COMMIT = "the current DHCP address pool"
# Host Asset File Table Header Pattern
HOST_ASSET_TABLE_HEADER = /^\"Tracking\",\"IP\",\"DNS\",\"NetBIOS\",\"OS\",\"OS CPE\"\s*$/

### Define a user feedback mechanism to show the script is running ###
def show_wait_spinner(fps=120)
  chars = %w[| / - \\]
  delay = 1.0/fps
  iter = 0
  spinner = Thread.new do
    while iter do  # Keep spinning until told otherwise
      print chars[(iter+=1) % chars.length]
      sleep delay
      print "\b"
    end
  end
  yield.tap{       # After yielding to the block, save the return value
    iter = false   # Tell the thread to exit, cleaning up after itself…
    spinner.join   # …and wait for it to do so.
  }                # Use the block's return value as the method's
end

### Create a method to remove the Qualys file header from host asset CSV file downloads ###
def chop_file_header(file_str, header_row_pattern)
  # Create a toggle condition for outputting lines we want
  header_flag = false
  # Create a temp file with the lines we want to keep
  File.open('temp_file.txt', 'w') do |temp_file|
    File.foreach(file_str) do |line|
      # Check each line for the header row pattern and toggle the header flag when it's seen
      header_flag = true if line =~ header_row_pattern
      # Output lines to the temp file when the header flag indicates the header has been seen
      temp_file.puts line if header_flag
    end
  end
  # Overwrite the host asset file with the temp file and cleanup the temp file
  %x{cp temp_file.txt "#{file_str}" && rm -f temp_file.txt}
end

### Create a method to read an IP list from a csv file and return it as an array ###
def read_csv_file(file_str, header_str)
  return_arry = Array.new
  CSV.foreach(file_str, headers:true) { |record| return_arry << record[header_str] }
  return_arry
end

### Create a method to read a text file IP list into an array ###
def read_txt_file(file_str)
  return_arry = Array.new
  IO.foreach(file_str) { |line| return_arry << line.chomp }
  return_arry
end

### Create a method to convert strings to IPs ###
def to_ip(str)
  IPAddr.new(str)
end

### Create a method to convert IPs to strings whether in ranges or single IPs ###
def to_string(ipaddr_object)
  case
    when ipaddr_object.class == Range && ipaddr_object.begin.class == IPAddr
      "#{ipaddr_object.begin}-#{ipaddr_object.end}"
    when ipaddr_object.class == IPAddr
      ipaddr_object.to_s
    else
      nil
  end
end

### Create a method to convert IP string ranges to IPAddr object arrays ###
def to_lst(str)
  # Split the string on dash if it has a dash
  rng = str.split("-") if str =~ /-/
  # Generate the list if the string had a dash
  Range.new(to_ip(rng[0]), to_ip(rng[1])).to_a if str =~ /-/
end

### Create a method to expand lists of IP string ranges and IPs to one long list of individual IPs ###
def expand_list(arry)
  # Transform the input array
  arry.map! do |elem|
    if elem =~ /-/     # Test each element for a dash
      to_lst elem      # If the element has a dash, invoke the to_lst method
    else
      to_ip elem       # If no dash just return the element as an IPAddr object
    end
  end
  arry.flatten!.sort!  # Ensure the resulting array is a flattened and sorted list
  arry.map { |elem| elem.to_s } # Return the IPAddr object array as a list of strings
end

### Create a method to simplify writing an array out to a text file ###
def array_to_file(file_str, arry)
  ## If the file_str includes a parent directory ensure the directory exists ##
  # Set file_str_path_depth
  file_str =~ /\// ? file_str_path_depth = file_str.split("/").length : file_str_path_depth = 1
  case
    # Check for a path depth greater than one directory
    when file_str_path_depth > 2
      # Set the directory variable with the path
      directory = file_str.split("/")[0..-2].join("/")
    # Check for a single parent directory
    when file_str_path_depth == 2
      # Set the directory variable with the parent directory name
      directory = file_str.split("/")[0]
  end
  # Create the parent director(y|ies) if needed
  FileUtils.mkdir_p directory if file_str_path_depth > 1 && !File.exists?(directory)
  # Open the file passed in file_str and write to it
  File.open(file_str, 'w') do |file|
    arry.each { |line| file.puts line }
  end
end

### Create a method for commiting a written name tracking file to the git repo ###
def commit(file_str, commit_type_str)
  # Set a git repo status flag
  repo_initialized = true
  # Set the git repo status flag to false if there's no initialized git repo
  repo_initialized = false if !File.exist? ".git"
  # Set a .gitignore status flag
  compliant_gitignore = true
  # Set the .gitignore status flag to false if it isn't in the state it should be
  compliant_gitignore = false if !File.file? ".gitignore" || (Digest::SHA512.file ".gitignore").to_s != GITIGNORE_DIGEST
  # Set .gitignore to desired state if not in compliance
  array_to_file(".gitignore", GITIGNORE) if !compliant_gitignore
  # Use a case statement to ensure the git repo is initialized and any .gitignore corrections are committed first
  case
    # Check if the git repo is initialized
    when !repo_initialized
      # Initialize the git repo, add the .gitignore file, and make the initial commit
      %x{git init && git add .gitignore && git commit -m "Initial commit"}
    # Check if the git repo is initialized and the .gitignore file was out of compliance
    when repo_initialized && !compliant_gitignore
      # Add the .gitignore file and commit those corrections
      %x{git add .gitignore && git commit -m "Fix non-compliant .gitignore"}
  end
  # Add the untracked file to be commited
  %x{git add "#{file_str}"}
  # Commit the file
  %x{git commit -m "Update the #{file_str} file with #{commit_type_str}"}
end

### Create a method for retrieving git diff HEAD output ###
def git_diff_head
  %x{git diff HEAD}.split("\n")
end

### Create a method to filter diff output for adds and deletes ###
def diff_filter(arry_of_strs, add_or_delete_str_lit)
  # Set filter pattern for additions if method call specifies adds
  filter_pattern = /^\+([0-9]{1,3}\.){3}[0-9]{1,3}$/ if add_or_delete_str_lit == "adds"
  # Set filter pattern for additions if method call specifies deletes
  filter_pattern = /^\-([0-9]{1,3}\.){3}[0-9]{1,3}$/ if add_or_delete_str_lit == "deletes"
  # Select desired values, remove the leading character, and return the resulting array
  (arry_of_strs.select { |elem| elem =~ filter_pattern }).collect { |elem| elem[1..-1] }
end

### Add a method to compress an expanded IPAddr object list back down to ranges ###
def list_compress(ipaddr_objects)
  return_arry = []
  # Ensure there's no way the array object passed to the method is modified in place outside this method
  ipaddr_objects = ipaddr_objects.dup
  # Convert any string elements in the array object passed to IPAddr objects
  ipaddr_objects.map! do |ipaddr_object|
    # Does the current iteration object have class String and does it match the IPv4 address pattern?
    if ipaddr_object.class == String && ipaddr_object =~ /([0-9]{1,3}\.){3}[0-9]{1,3}/
      # Convert the string to an IPAddr object
      to_ip ipaddr_object
    else
      # Do nothing except return the object (an error will get thrown later if class is other than expected)
      ipaddr_object
    end
  end
  ipaddr_objects.each do |ipaddr_object|
    case
      # Current interation object has class IPAddr and the last return array element has class IPAddr
      when ipaddr_object.class == IPAddr && return_arry[-1].class == IPAddr
        # Is the current iteration object contiguous with the last return array element value?
        if return_arry[-1].succ == ipaddr_object
          # Convert the last return array element to a range object ending with the current iteration object
          return_arry[-1] = Range.new(return_arry[-1], ipaddr_object)
        # Or is the current iteration object equal to the last return array element value?
        elsif return_arry[-1] >= ipaddr_object
          # Do nothing
        else
          # Append non-contiguous iteration objects to the return array when neither of the if statement conditions are met
          return_arry << ipaddr_object
        end
      # Current iteration object has class IPAddr and the last return array element has class Range
      when ipaddr_object.class == IPAddr && return_arry[-1].class == Range
        # Is the current iteration object contiguous with (1 greater than) the end of the last return array range object?
        if return_arry[-1].end.succ == ipaddr_object
          # Add the current iteration object to the end of the last return array range object
          return_arry[-1] = Range.new(return_arry[-1].begin, ipaddr_object)
        # Or is the last return array IPAddr object greater than or eaqual to the current iteration object?
        elsif return_arry[-1].end >= ipaddr_object
          # Do nothing
        else
          # Append non-contiguous iteration objects to the return array when neither of the if statement conditions are met
          return_arry << ipaddr_object
        end
      # The last element of the return array will be nil on the first iteration since the return array will be empty at that point
      when return_arry[-1].class == NilClass
        # Append the first iteration object to the return array
        return_arry << ipaddr_object
      else
        # Output an error if a return array element has a class other than IPAddr, Range, or NilClass
        puts "Invalid object class passed to list_compress"
    end
    # Test return array Range objects for length of zero
    if return_arry[-1].class == Range && return_arry[-1].begin == return_arry[-1].end
      # Convert zero length Range objects to IPAddr objects
      return_arry[-1] = IPAddr.new(return_arry[-1].begin, return_arry[-1].begin.family)
    end
  end
  # Return the array to the caller
  return_arry.map { |list_elem| to_string list_elem }
end

### Remove the Qualys file header from the name tracking file ###
print "Removing the Qualys File Header from the #{QUALYS_NAME_TRACKING_FILE} file..."
show_wait_spinner { chop_file_header(QUALYS_NAME_TRACKING_FILE, HOST_ASSET_TABLE_HEADER) }
puts "done!"

### Get the IP list from the Qualys host asset name tracking file ###
print "Getting the IP list from the #{QUALYS_NAME_TRACKING_FILE} file..."
name_tracked_host_assets = show_wait_spinner { read_csv_file(QUALYS_NAME_TRACKING_FILE, "IP") }
puts "done!"

### Convert the list of name tracked host asset IPs to a long list of individual IPs ###
print "Expanding the list of IPs retrieved from the #{QUALYS_NAME_TRACKING_FILE} file..."
name_tracked_host_assets = show_wait_spinner { expand_list name_tracked_host_assets }
puts "done!"

### Write the expanded list of name tracked host asset IPs to a text file ###
print "Writing the expanded IP list from the #{QUALYS_NAME_TRACKING_FILE} file to the #{NAME_TRACKING_FILE} file..."
show_wait_spinner { array_to_file(NAME_TRACKING_FILE, name_tracked_host_assets) }
puts "done!"

### Commit the name tracked host asset IPs text file to the git repo ###
print "Committing changes written to the #{NAME_TRACKING_FILE} file..."
show_wait_spinner { commit(NAME_TRACKING_FILE, QUALYS_NAME_TRACKING_COMMIT) }
puts "done!"

### Read the DHCP address pool file into an array ###
print "Retrieving the list of IPs from the #{DHCP_ADDRESS_POOL_FILE} file..."
dhcp_address_pool = show_wait_spinner { read_txt_file DHCP_ADDRESS_POOL_FILE }
puts "done!"

### Convert the DHCP address pool to an expanded list ###
print "Expanding the list of IPs retrieved from the #{DHCP_ADDRESS_POOL_FILE} file..."
dhcp_address_pool = show_wait_spinner { expand_list dhcp_address_pool }
puts "done!"

### Write the expanded DHCP address pool to a text file ###
print "Writing the expanded IP list from the #{DHCP_ADDRESS_POOL_FILE} file to the #{NAME_TRACKING_FILE} file..."
show_wait_spinner { array_to_file(NAME_TRACKING_FILE, dhcp_address_pool) }
puts "done!"

### Run a git diff to expose changes required for Qualys host asset tracking by DNS name ###
print "Running a git diff to expose the needed changes to Qualys Host Asset Tracking by DNS Name..."
git_diff_output = show_wait_spinner { git_diff_head }
puts "done!"

### Capture IP assets that must be moved to Qualys host asset tracking by DNS name from track by IP ###
print "Capturing required additions to Qualys Host Asset Tracking by DNS Name..."
name_tracking_adds = show_wait_spinner { diff_filter(git_diff_output, "adds") }
puts "done!"

### Capture IP assets that must be moved from Qualys host asset tracking by DNS name to track by IP ###
print "Capturing required deletions from Qualys Host Asset Tracking by DNS Name..."
name_tracking_deletes = show_wait_spinner { diff_filter(git_diff_output, "deletes") }
puts "done!"

### Commit the dhcp_address_pool array contents that was written to the NAME_TRACKING_FILE ###
print "Committing changes written to the #{NAME_TRACKING_FILE} file..."
show_wait_spinner { commit(NAME_TRACKING_FILE, DHCP_POOL_COMMIT) }
puts "done!"

### Remove the Qualys file header from the IP tracking file ###
print "Removing the Qualys File Header from the #{QUALYS_IP_TRACKING_FILE} file..."
show_wait_spinner { chop_file_header(QUALYS_IP_TRACKING_FILE, HOST_ASSET_TABLE_HEADER) }
puts "done!"

### Get the IP list from the Qualys host asset IP tracking file ###
print "Getting the IP list from the #{QUALYS_IP_TRACKING_FILE} file..."
ip_tracked_host_assets = show_wait_spinner { read_csv_file(QUALYS_IP_TRACKING_FILE, "IP") }
puts "done!"

### Convert the list of IP tracked host asset IPs to a long list of individual IPs ###
print "Expanding the list of IPs retrieved from the #{QUALYS_IP_TRACKING_FILE} file..."
ip_tracked_host_assets = show_wait_spinner { expand_list ip_tracked_host_assets }
puts "done!"

### Write the expanded list of the IP tracked host asset IPs to a text file ###
print "Writing the expanded IP list from the #{QUALYS_IP_TRACKING_FILE} file to the #{SUBSCRIPTION_ADD_CHECK_FILE} file..."
show_wait_spinner { array_to_file(SUBSCRIPTION_ADD_CHECK_FILE, ip_tracked_host_assets) }
puts "done!"

### Commit the ip_tracked_host_assets array contents that was written to the SUBSCRIPTION_ADD_CHECK_FILE ###
print "Committing changes written to the #{SUBSCRIPTION_ADD_CHECK_FILE} file..."
show_wait_spinner { commit(SUBSCRIPTION_ADD_CHECK_FILE, QUALYS_IP_TRACKING_COMMIT) }
puts "done!"

### Write the contents of the name_tracking_adds array to the SUBSCRIPTION_ADD_CHECK_FILE ###
print "Writing the captured additions to Qualys Host Asset Tracking by DNS Name to the #{SUBSCRIPTION_ADD_CHECK_FILE} file..."
show_wait_spinner { array_to_file(SUBSCRIPTION_ADD_CHECK_FILE, name_tracking_adds) }
puts "done!"

### Run a git diff to expose subscription additions required to support a name tracking add API call to Qualys ###
print "Running a git diff to expose the needed additions to the Qualys Subscription..."
git_diff_output = show_wait_spinner { git_diff_head }
puts "done!"

### Capture IP assets that must be added to the Qualys subscription because they were not found in name or IP tracking ###
print "Capturing the IP assets that must be added to the Qualys subscription because they were not found in name or IP tracking..."
qualys_subscription_adds = show_wait_spinner { diff_filter(git_diff_output, "adds") }
puts "done!"

### Commit the name_tracking_adds array contents that was written to the SUBSCRIPTION_ADD_CHECK_FILE ###
print "Committing changes written to the #{SUBSCRIPTION_ADD_CHECK_FILE} file..."
show_wait_spinner { commit(SUBSCRIPTION_ADD_CHECK_FILE, QUALYS_NAME_TRACKING_COMMIT) }
puts "done!"

### Collapse the contents of the name_tracking_adds array and write it to a file ###
print "Writing the needed additions to Qualys Host Asset Tracking by DNS Name to the #{NAME_TRACKING_ADDS_FILE} file..."
show_wait_spinner { array_to_file(NAME_TRACKING_ADDS_FILE, (list_compress name_tracking_adds)) }
puts "done!"

### Collapse the contents of the name_tracking_deletes array and write it to a file ###
print "Writing the needed deletions from Qualys Host Asset Tracking by DNS Name to the #{NAME_TRACKING_DELETES_FILE} file..."
show_wait_spinner { array_to_file(NAME_TRACKING_DELETES_FILE, (list_compress name_tracking_deletes)) }
puts "done!"

### Collapse the contents of the qualys_subscription_adds array and write it to a file ###
print "Writing the needed additions to the Qualys Subscription to the #{SUBSCRIPTION_ADDS_FILE} file..."
show_wait_spinner { array_to_file(SUBSCRIPTION_ADDS_FILE, (list_compress qualys_subscription_adds)) }
puts "done!"
