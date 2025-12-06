/*
hexreplace - Binary patcher for Frida iOS
Patches frida-server and frida-agent.dylib to evade detection

Usage: hexreplace <input> <new_name> <output>
  - input: path to frida binary
  - new_name: 5 lowercase letters (a-z)
  - output: path for patched binary

Example: hexreplace frida-server abcde frida-server-patched
*/
package main

import (
	"debug/macho"
	"encoding/binary"
	"fmt"
	"io"
	"os"
)

type Replacement struct {
	Old []byte
	New []byte
}

func main() {
	if len(os.Args) != 4 {
		fmt.Println("Usage: hexreplace <input> <new_name> <output>")
		fmt.Println("  new_name: 5 lowercase letters (a-z)")
		os.Exit(1)
	}

	inputPath := os.Args[1]
	newName := os.Args[2]
	outputPath := os.Args[3]

	if len(newName) != 5 || !isLowerAlpha(newName) {
		fmt.Println("Error: new_name must be exactly 5 lowercase letters (a-z)")
		os.Exit(1)
	}

	if err := copyFile(inputPath, outputPath); err != nil {
		fmt.Printf("Error copying file: %v\n", err)
		os.Exit(1)
	}

	if err := patchFile(outputPath, newName); err != nil {
		fmt.Printf("Error patching file: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("Patch successful:", outputPath)
}

func isLowerAlpha(s string) bool {
	for _, c := range s {
		if c < 'a' || c > 'z' {
			return false
		}
	}
	return true
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()

	if _, err := io.Copy(out, in); err != nil {
		return err
	}

	return os.Chmod(dst, 0755)
}

func patchFile(filePath, newName string) error {
	// Try to open as fat binary first
	if fatFile, err := macho.OpenFat(filePath); err == nil {
		defer fatFile.Close()
		fmt.Printf("Detected: Fat MachO with %d architectures\n", len(fatFile.Arches))
		for i, arch := range fatFile.Arches {
			fmt.Printf("  [%d] %s\n", i+1, describeCPU(arch.Cpu))
			if err := patchArch(arch.File, filePath, uint64(arch.Offset), newName); err != nil {
				return fmt.Errorf("failed to patch arch %d: %w", i+1, err)
			}
		}
		return nil
	}

	// Try single architecture
	if machoFile, err := macho.Open(filePath); err == nil {
		defer machoFile.Close()
		fmt.Printf("Detected: MachO %s\n", describeCPU(machoFile.Cpu))
		return patchArch(machoFile, filePath, 0, newName)
	}

	return fmt.Errorf("unsupported file format (not MachO)")
}

func describeCPU(cpu macho.Cpu) string {
	switch cpu {
	case macho.CpuArm:
		return "ARM"
	case macho.CpuArm64:
		return "ARM64"
	case macho.CpuAmd64:
		return "x86_64"
	case macho.Cpu386:
		return "x86"
	default:
		return fmt.Sprintf("Unknown(%d)", cpu)
	}
}

func patchArch(file *macho.File, filePath string, baseOffset uint64, newName string) error {
	replacements := buildReplacements(newName)

	for _, section := range []string{"__cstring", "__const"} {
		sec := file.Section(section)
		if sec == nil {
			continue
		}

		data, err := sec.Data()
		if err != nil {
			fmt.Printf("  Warning: cannot read %s: %v\n", section, err)
			continue
		}

		modified, count := applyReplacements(data, replacements)
		if count > 0 {
			offset := baseOffset + uint64(sec.Offset)
			if err := writeAt(filePath, offset, modified); err != nil {
				return fmt.Errorf("failed to write %s: %w", section, err)
			}
			fmt.Printf("  Patched %s: %d replacements\n", section, count)
		}
	}

	return nil
}

func buildReplacements(newName string) []Replacement {
	// newName is 5 chars, same length as "frida"
	return []Replacement{
		// Server identifiers
		{Old: []byte("frida_server_"), New: []byte(newName + "_server_")},
		{Old: []byte("frida-server-main-loop"), New: []byte(newName + "-server-main-loop")},
		{Old: []byte("frida-main-loop"), New: []byte(newName + "-main-loop")},

		// RPC identifier
		{Old: []byte("frida:rpc"), New: []byte(newName + ":rpc")},

		// Agent paths
		{Old: []byte("frida-agent.dylib"), New: []byte(newName + "-agent.dylib")},
		{Old: []byte("/usr/lib/frida/"), New: []byte("/usr/lib/" + newName + "/")},

		// Gum prefix (use first 3 chars)
		{Old: []byte("gum-js-loop"), New: []byte(newName[:3] + "-js-loop")},
		{Old: []byte("gum-"), New: []byte(newName[:3] + "-")},
	}
}

func applyReplacements(data []byte, replacements []Replacement) ([]byte, int) {
	modified := make([]byte, len(data))
	copy(modified, data)

	totalCount := 0
	for _, r := range replacements {
		if len(r.Old) != len(r.New) {
			// For different lengths, pad with null bytes
			padded := make([]byte, len(r.Old))
			copy(padded, r.New)
			r.New = padded
		}

		for i := 0; i <= len(modified)-len(r.Old); i++ {
			if bytesEqual(modified[i:i+len(r.Old)], r.Old) {
				copy(modified[i:i+len(r.Old)], r.New)
				totalCount++
			}
		}
	}

	return modified, totalCount
}

func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func writeAt(filePath string, offset uint64, data []byte) error {
	f, err := os.OpenFile(filePath, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer f.Close()

	_, err = f.WriteAt(data, int64(offset))
	return err
}

// For debugging: check byte order
func init() {
	var test uint16 = 0x0102
	bytes := make([]byte, 2)
	binary.LittleEndian.PutUint16(bytes, test)
	_ = bytes // suppress unused warning
}
