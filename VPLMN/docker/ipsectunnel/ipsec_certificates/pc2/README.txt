IPsec Certificates for PC2 (HPLMN UPF)
========================================

Files:
- ca-cert.pem: Certificate Authority certificate (public)
- pc2-upf-cert.pem: PC2 UPF certificate (public)
- pc2-upf-key.pem: PC2 UPF private key (KEEP SECRET!)

Installation on PC2:
1. Copy all files to PC2
2. Run: sudo ./02_install_certs_pc2.sh
3. Run: sudo ./03_setup_ipsec_pc2_cert.sh

Identity: upf.5gc.mnc001.mcc001.3gppnetwork.org
IP Address: 10.162.149.24
