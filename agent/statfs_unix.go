//go:build unix

package main

import "syscall"

// statfsUsage reports the size and use of the filesystem holding path.
// total = blocks*bsize and used = (blocks-bfree)*bsize. The agent points it
// at /host/etc/hostname, a file bind-mounted from the host, so it measures
// the host's root filesystem and not the container's.
func statfsUsage(path string) (total, used uint64, err error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, 0, err
	}
	// The field widths differ between linux and darwin.
	bsize, blocks, free := uint64(st.Bsize), uint64(st.Blocks), uint64(st.Bfree)
	if free > blocks {
		return 0, 0, syscall.EINVAL
	}
	return blocks * bsize, (blocks - free) * bsize, nil
}
