-- Upgrade Firecracker from v1.10.1 to v1.15.1 (CVE-2026-5747 fix)
-- Upgrade Guest Kernel from 6.1.102 to 6.1.158 (65 patches behind stable)
-- Note: Existing snapshots must be regenerated after this upgrade (snapshot format v5.0.0+)

ALTER TABLE env_builds ALTER COLUMN firecracker_version SET DEFAULT 'v1.15.1_b2d9ccc';
ALTER TABLE env_builds ALTER COLUMN kernel_version SET DEFAULT 'vmlinux-6.1.158';
