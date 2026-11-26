//go:build unix

package main

import (
	"errors"
	"syscall"
)

// statfsUsage reports the size and use of the filesystem holding path.
// The agent points it at /host/etc/hostname, a file bind-mounted from the
// host, which on an ordinary machine sits on the root filesystem.
func statfsUsage(path string) (total, used uint64, err error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, 0, err
	}
	// The field widths differ between linux and darwin.
	return diskUsage(uint64(st.Type), uint64(st.Bsize), uint64(st.Blocks), uint64(st.Bfree))
}

// Linux magic numbers for filesystems that live in memory. darwin's f_type
// values are small integers, so they never match.
const (
	tmpfsMagic = 0x01021994
	ramfsMagic = 0x858458f6
)

var errNotDisk = errors.New("filesystem lives in memory, not on a disk")

// diskUsage is total = blocks*bsize and used = (blocks-bfree)*bsize. When
// /etc/hostname sits on a tmpfs (as inside Docker-in-Docker), the numbers
// describe memory, not the disk, so they are refused rather than shown.
func diskUsage(fsType, bsize, blocks, free uint64) (total, used uint64, err error) {
	if fsType == tmpfsMagic || fsType == ramfsMagic {
		return 0, 0, errNotDisk
	}
	if free > blocks {
		return 0, 0, syscall.EINVAL
	}
	return blocks * bsize, (blocks - free) * bsize, nil
}
