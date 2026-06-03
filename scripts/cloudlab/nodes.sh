# CloudLab node public hostnames — sourced by bootstrap.sh and deploy.sh.
# (Not meant to be executed directly; it only defines the NODES array.)
#
# node-0 MUST be first and must line up with the internal-IP order in
# config.json (10.0.0.101 == node-0, etc.). Update this list each time you
# swap CloudLab experiments.
NODES=(
	"apt147.apt.emulab.net"   # node-0 / 10.0.0.101  (control-plane)
	"apt156.apt.emulab.net"   # node-1 / 10.0.0.102
	"apt159.apt.emulab.net"   # node-2 / 10.0.0.103
	"apt162.apt.emulab.net"   # node-3 / 10.0.0.104
	"apt139.apt.emulab.net"   # node-4 / 10.0.0.105
)
