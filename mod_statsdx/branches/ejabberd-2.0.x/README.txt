
	mod_statsdx - Calculates and gathers statistics actively

        Homepage: http://www.ejabberd.im/mod_statsdx
        Author: Badlop
        Requirements: ejabberd 2.0.x


	mod_statsdx
	==============

Measures several statistics, and provides a new section in ejabberd
Web Admin to view them.


	CONFIGURE
	---------

Enable the module in ejabberd.cfg for example with a basic configuration:
{modules, [
  ...
  {mod_statsdx, []}
 ]}.

Configurable options:
  hooks: Set to 'true' to enable hooks and related statistics.
         This option by default 'false' because it is expected to
	 consume many resources in very populated servers.


	EXAMPLE CONFIGURATION
	---------------------

{modules, [
  ...
  {mod_statsdx, [{hooks, true}]}
 ]}.


	FEATURE REQUESTS
	----------------

 - fix the problem with plain/ssl/tlsusers, it crashes ejabberd
 - traffic: send bytes per second, received bps
 - connections to a transport
 - traffic: send presence per second, received mps
 - Number of SASL c2s connections
 - improve to work in distributed server



	mod_stats2file
	==============

	Generates files with all kind of statistics

This module writes a file with all kind of statistics every few minutes. 
Available output formats are html (example), 
text file with descriptions and raw text file (for MRTG, RRDTool...).


	CONFIGURE
	---------

This module requires mod_statsdx. 

Enable the module in ejabberd.cfg for example with a basic configuration:
{modules, [
  ...
  {mod_stats2file, []}
 ]}.

Configurable options:
  interval: Time between updates, in minutes (default: 5)
  type: Type of output. Allowed values: html, txt, dat (default: html)
  basefilename: Base filename including absolute path (default: "/tmp/ejasta")
  split: If split the statistics in several files (default: false)
  hosts: List of virtual hosts that will be checked. By default all


	EXAMPLE CONFIGURATION
	---------------------

{modules, [
  ...
  {mod_stats2file, [{interval, 60},
                    {type, txt},
                    {split, true},
                    {basefilename, "/var/www/stats"},
                    {hosts, ["localhost", "server3.com"]}
                   ]}
 ]}.


