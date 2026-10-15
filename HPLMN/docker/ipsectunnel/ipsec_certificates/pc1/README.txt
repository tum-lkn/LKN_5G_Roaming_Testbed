IPsec Certificates for PC1 (VPLMN UPF)
========================================

Files:
- ca-cert.pem: Certificate Authority certificate (public)
- pc1-upf-cert.pem: PC1 UPF certificate (public)
- pc1-upf-key.pem: PC1 UPF private key (KEEP SECRET!)

Installation on PC1:
1. Copy all files to PC1
2. Run: sudo ./02_install_certs_pc1.sh
3. Run: sudo ./03_setup_ipsec_pc1_cert.sh

Identity: upf.5gc.mnc071.mcc999.3gppnetwork.org
IP Address: 10.0.0.10
