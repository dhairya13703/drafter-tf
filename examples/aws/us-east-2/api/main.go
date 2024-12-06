package main

import (
	"bytes"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

type DrafterAPI struct {
	router *gin.Engine
}

type LogManager struct {
	baseDir  string
	vmName   string
	logFiles map[string]*os.File
}

type VMConfig struct {
	Name      string `json:"name"`
	Memory    string `json:"memory"`
	CPUs      int    `json:"cpus"`
	DiskSize  string `json:"disk_size"`
	ImagePath string `json:"image_path"`
}

func NewLogManager(vmName string) (*LogManager, error) {
	baseDir := filepath.Join("/home/ec2-user/drafter-api/logs", vmName, time.Now().Format("2006-01-02_15-04-05"))
	if err := os.MkdirAll(baseDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create log directory: %v", err)
	}

	return &LogManager{
		baseDir:  baseDir,
		vmName:   vmName,
		logFiles: make(map[string]*os.File),
	}, nil
}

func (lm *LogManager) GetLogger(component string) (*log.Logger, error) {
	logPath := filepath.Join(lm.baseDir, fmt.Sprintf("%s.log", component))
	f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return nil, fmt.Errorf("failed to open log file: %v", err)
	}

	lm.logFiles[component] = f
	return log.New(f, fmt.Sprintf("[%s] ", component), log.LstdFlags|log.Lmsgprefix), nil
}

func (lm *LogManager) Close() {
	for _, f := range lm.logFiles {
		f.Close()
	}
}

func (api *DrafterAPI) setupLogging(vmName string) (*LogManager, error) {
	return NewLogManager(vmName)
}

func runCommandWithOutput(cmd *exec.Cmd) (string, error) {
	// Create a buffer to capture both stdout and stderr
	var stdout, stderr bytes.Buffer
	cmd.Stdout = io.MultiWriter(&stdout, os.Stdout) // Write to both buffer and terminal
	cmd.Stderr = io.MultiWriter(&stderr, os.Stderr) // Write to both buffer and terminal

	log.Printf("Executing command: %s %v", cmd.Path, cmd.Args)
	err := cmd.Run()
	if err != nil {
		return "", fmt.Errorf("error: %v, stderr: %s", err, stderr.String())
	}

	// Log the output
	output := stdout.String()
	if output != "" {
		log.Printf("Command output: %s", output)
	}

	return output, nil
}

func NewDrafterAPI() *DrafterAPI {
	api := &DrafterAPI{
		router: gin.Default(),
	}
	api.setupRoutes()
	return api
}

func (api *DrafterAPI) setupRoutes() {
	api.router.POST("/vm/create", api.createVM)
	api.router.POST("/vm/start/:name", api.startVM)
	api.router.POST("/vm/stop/:name", api.stopVM)
	api.router.GET("/vm/status/:name", api.getVMStatus)
	api.router.POST("/vm/migrate/:name", api.migrateVM)
}

func (api *DrafterAPI) downloadAndVerifyFile(url, outputPath string) error {
	log.Printf("Starting download from: %s", url)

	// Create a custom HTTP client with longer timeout
	client := &http.Client{
		Timeout: 5 * time.Minute,
	}

	// Make HTTP request
	resp, err := client.Get(url)
	if err != nil {
		return fmt.Errorf("HTTP request failed: %v", err)
	}
	defer resp.Body.Close()

	// Check response status
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("bad HTTP response: %s", resp.Status)
	}

	log.Printf("Response headers: %+v", resp.Header)
	log.Printf("Content length: %d", resp.ContentLength)

	// Create output file
	out, err := os.Create(outputPath)
	if err != nil {
		return fmt.Errorf("failed to create output file: %v", err)
	}
	defer out.Close()

	// Copy the response body to the file
	written, err := io.Copy(out, resp.Body)
	if err != nil {
		return fmt.Errorf("failed to write file: %v", err)
	}

	log.Printf("Successfully downloaded %d bytes to %s", written, outputPath)

	// Verify file exists and has content
	fileInfo, err := os.Stat(outputPath)
	if err != nil {
		return fmt.Errorf("failed to stat downloaded file: %v", err)
	}

	if fileInfo.Size() == 0 {
		return fmt.Errorf("downloaded file is empty")
	}

	// Check file content
	fileContent, err := os.ReadFile(outputPath)
	if err != nil {
		return fmt.Errorf("failed to read downloaded file: %v", err)
	}

	log.Printf("File size: %d bytes, First 32 bytes: %x", len(fileContent), fileContent[:min(32, len(fileContent))])

	return nil
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func (api *DrafterAPI) createVM(c *gin.Context) {
	var config VMConfig
	if err := c.BindJSON(&config); err != nil {
		log.Printf("Error parsing request: %v", err)
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	// Add this logging setup right here
	logManager, err := api.setupLogging(config.Name)
	if err != nil {
		log.Printf("Error setting up logging: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("Failed to setup logging: %v", err)})
		return
	}
	defer logManager.Close()

	// Get loggers for different components
	natLogger, err := logManager.GetLogger("nat")
	if err != nil {
		log.Printf("Error creating NAT logger: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("Failed to create NAT logger: %v", err)})
		return
	}

	snapshotLogger, err := logManager.GetLogger("snapshotter")
	if err != nil {
		log.Printf("Error creating snapshotter logger: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("Failed to create snapshotter logger: %v", err)})
		return
	}

	// Use /home/ec2-user as the base directory
	baseOutDir := "/home/ec2-user/out"
	blueprintDir := filepath.Join(baseOutDir, "blueprint")
	packageDir := filepath.Join(baseOutDir, "package")
	instanceDir := filepath.Join(baseOutDir, fmt.Sprintf("instance-0", config.Name))
	overlayDir := filepath.Join(instanceDir, "overlay")
	stateDir := filepath.Join(instanceDir, "state")

	log.Printf("Creating VM: %s", config.Name)
	log.Printf("Using directories: base=%s, blueprint=%s", baseOutDir, blueprintDir)

	// Clean up existing directories if they exist
	if err := os.RemoveAll(baseOutDir); err != nil {
		log.Printf("Error cleaning up existing directories: %v", err)
	}

	// Create all directories
	dirs := []string{blueprintDir, packageDir, overlayDir, stateDir}
	for _, dir := range dirs {
		if err := os.MkdirAll(dir, 0755); err != nil {
			log.Printf("Error creating directory %s: %v", dir, err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("Failed to create directory %s: %v", dir, err)})
			return
		}
	}

	// Set proper permissions
	chownCmd := exec.Command("sudo", "chown", "-R", "ec2-user:ec2-user", baseOutDir)
	if err := chownCmd.Run(); err != nil {
		log.Printf("Error setting permissions: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("Failed to set permissions: %v", err)})
		return
	}

	// Download DrafterOS with explicit version
	drafterosPath := filepath.Join(baseOutDir, "drafteros-oci.tar.zst")
	// Use a specific version instead of latest
	downloadURL := fmt.Sprintf("https://github.com/loopholelabs/drafter/releases/download/v0.5.0/drafteros-oci-x86_64_pvm.tar.zst")
	fmt.Println(downloadURL)
	if err := api.downloadAndVerifyFile(downloadURL, drafterosPath); err != nil {
		log.Printf("Error downloading DrafterOS: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("Failed to download DrafterOS: %v", err)})
		return
	}

	// Download Valkey OCI with explicit version
	valkeyPath := filepath.Join(baseOutDir, "oci-valkey.tar.zst")
	valkeyURL := fmt.Sprintf("https://github.com/loopholelabs/drafter/releases/download/v0.5.0/oci-valkey-x86_64.tar.zst")
	if err := api.downloadAndVerifyFile(valkeyURL, valkeyPath); err != nil {
		log.Printf("Error downloading Valkey OCI: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("Failed to download Valkey OCI: %v", err)})
		return
	}

	// Verify downloaded files
	log.Printf("Verifying downloaded files...")
	if _, err := os.Stat(drafterosPath); err != nil {
		log.Printf("DrafterOS file not found: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "DrafterOS file missing after download"})
		return
	}
	if _, err := os.Stat(valkeyPath); err != nil {
		log.Printf("Valkey file not found: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Valkey file missing after download"})
		return
	}

	// Configure sudo path
	sudoPathCmd := exec.Command("sudo", "tee", "/etc/sudoers.d/preserve_path")
	sudoPathCmd.Stdin = strings.NewReader("Defaults    secure_path = /sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin:/usr/local/sbin\n")
	if err := sudoPathCmd.Run(); err != nil {
		log.Printf("Error configuring sudo path: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("Failed to configure sudo path: %v", err)})
		return
	}

	// Load NBD module
	if err := exec.Command("sudo", "modprobe", "nbd", "nbds_max=4096").Run(); err != nil {
		log.Printf("Error loading NBD module: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("Failed to load NBD module: %v", err)})
		return
	}

	// Extract DrafterOS blueprint
	log.Printf("Extracting DrafterOS blueprint from %s", drafterosPath)
	extractDevices := fmt.Sprintf(`[{"name":"kernel","path":"%s"},{"name":"disk","path":"%s"}]`,
		filepath.Join(blueprintDir, "vmlinux"),
		filepath.Join(blueprintDir, "rootfs.ext4"))

	extractCmd := exec.Command("sudo", "drafter-packager",
		"--package-path", drafterosPath,
		"--extract",
		"--devices", extractDevices)

	log.Printf("Running extraction command with devices: %s", extractDevices)
	if out, err := runCommandWithOutput(extractCmd); err != nil {
		log.Printf("Error extracting DrafterOS: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("Failed to extract DrafterOS: %v", err)})
		return
	} else {
		log.Printf("DrafterOS extraction output: %s", out)
	}

	// Extract Valkey OCI
	log.Printf("Extracting Valkey OCI from %s", valkeyPath)
	extractValkeyDevices := fmt.Sprintf(`[{"name":"oci","path":"%s"}]`,
		filepath.Join(blueprintDir, "oci.ext4"))

	log.Printf("Running Valkey extraction command with devices: %s", extractValkeyDevices)
	extractValkeyCmd := exec.Command("sudo", "drafter-packager",
		"--package-path", valkeyPath,
		"--extract",
		"--devices", extractValkeyDevices)

	if out, err := runCommandWithOutput(extractValkeyCmd); err != nil {
		log.Printf("Error extracting Valkey OCI: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("Failed to extract Valkey OCI: %v", err)})
		return
	} else {
		log.Printf("Valkey OCI extraction output: %s", out)
	}

	// Verify extracted files
	files := []string{
		filepath.Join(blueprintDir, "vmlinux"),
		filepath.Join(blueprintDir, "rootfs.ext4"),
		filepath.Join(blueprintDir, "oci.ext4"),
	}

	for _, file := range files {
		if _, err := os.Stat(file); err != nil {
			log.Printf("Error: extracted file %s not found: %v", file, err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("Extracted file %s missing", file)})
			return
		}
		fileInfo, err := os.Stat(file)
		if err == nil {
			log.Printf("Extracted file %s size: %d bytes", file, fileInfo.Size())
		}
	}

	// Start NAT service
	natLogger.Printf("Starting NAT service")
	natCmd := exec.Command("sudo", "drafter-nat", "--host-interface", "eth0")
	natCmd.Stdout = logManager.logFiles["nat"]
	natCmd.Stderr = logManager.logFiles["nat"]
	if err := natCmd.Start(); err != nil {
		natLogger.Printf("Error starting NAT service: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("Failed to start NAT service: %v", err)})
		return
	}

	log.Printf("Waiting 5 seconds for NAT to initialize")
	time.Sleep(5 * time.Second)

	// Start snapshotter
	snapshotLogger.Printf("Starting snapshotter")
	snapshotterCmd := exec.Command("sudo", "drafter-snapshotter",
		"--netns", "ark0",
		"--cpu-template", "T2A",
		"--memory-size", config.Memory,
		"--devices", fmt.Sprintf(`[
        {
            "name": "state",
            "output": "/home/ec2-user/out/package/state.bin"
        },
        {
            "name": "memory",
            "output": "/home/ec2-user/out/package/memory.bin"
        },
        {
            "name": "kernel",
            "input": "/home/ec2-user/out/blueprint/vmlinux",
            "output": "/home/ec2-user/out/package/vmlinux"
        },
        {
            "name": "disk",
            "input": "/home/ec2-user/out/blueprint/rootfs.ext4",
            "output": "/home/ec2-user/out/package/rootfs.ext4"
        },
        {
            "name": "config",
            "output": "/home/ec2-user/out/package/config.json"
        },
        {
            "name": "oci",
            "input": "/home/ec2-user/out/blueprint/oci.ext4",
            "output": "/home/ec2-user/out/package/oci.ext4"
        }
    ]`))
	println(snapshotterCmd.String())
	snapshotterCmd.Stdout = logManager.logFiles["snapshotter"]
	snapshotterCmd.Stderr = logManager.logFiles["snapshotter"]
	if err := snapshotterCmd.Start(); err != nil {
		snapshotLogger.Printf("Error starting snapshotter: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("Failed to start snapshotter: %v", err)})
		return
	}

	log.Printf("VM creation initiated successfully: %s", config.Name)
	c.JSON(http.StatusOK, gin.H{"message": "VM creation initiated", "name": config.Name})
}

func (api *DrafterAPI) startVM(c *gin.Context) {
	name := c.Param("name")
	log.Printf("Starting VM: %s", name)

	// Setup logging
	logManager, err := api.setupLogging(name)
	if err != nil {
		log.Printf("Error setting up logging: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("Failed to setup logging: %v", err)})
		return
	}
	defer logManager.Close()

	// Set up peer service logging
	peerLogger, err := logManager.GetLogger("peer")
	if err != nil {
		log.Printf("Error creating peer logger: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("Failed to create peer logger: %v", err)})
		return
	}

	peerLogger.Printf("Starting peer service")
	peerCmd := exec.Command("sudo", "drafter-peer",
		"--netns", "ark0",
		"--raddr", "",
		"--laddr", ":1337",
		"--devices", fmt.Sprintf(`[
			{
					"name": "state",
					"base": "/home/ec2-user/out/package/state.bin",
					"overlay": "/home/ec2-user/out/instance-0/overlay/state.bin",
					"state": "/home/ec2-user/out/instance-0/state/state.bin",
					"blockSize": 65536,
					"expiry": 1000000000,
					"maxDirtyBlocks": 200,
					"minCycles": 5,
					"maxCycles": 20,
					"cycleThrottle": 500000000,
					"makeMigratable": true,
					"shared": false
			},
			{
					"name": "memory",
					"base": "/home/ec2-user/out/package/memory.bin",
					"overlay": "/home/ec2-user/out/instance-0/overlay/memory.bin",
					"state": "/home/ec2-user/out/instance-0/state/memory.bin",
					"blockSize": 65536,
					"expiry": 1000000000,
					"maxDirtyBlocks": 200,
					"minCycles": 5,
					"maxCycles": 20,
					"cycleThrottle": 500000000,
					"makeMigratable": true,
					"shared": false
			},
			{
					"name": "kernel",
					"base": "/home/ec2-user/out/package/vmlinux",
					"overlay": "/home/ec2-user/out/instance-0/overlay/vmlinux",
					"state": "/home/ec2-user/out/instance-0/state/vmlinux",
					"blockSize": 65536,
					"expiry": 1000000000,
					"maxDirtyBlocks": 200,
					"minCycles": 5,
					"maxCycles": 20,
					"cycleThrottle": 500000000,
					"makeMigratable": true,
					"shared": false
			},
			{
					"name": "disk",
					"base": "/home/ec2-user/out/package/rootfs.ext4",
					"overlay": "/home/ec2-user/out/instance-0/overlay/rootfs.ext4",
					"state": "/home/ec2-user/out/instance-0/state/rootfs.ext4",
					"blockSize": 65536,
					"expiry": 1000000000,
					"maxDirtyBlocks": 200,
					"minCycles": 5,
					"maxCycles": 20,
					"cycleThrottle": 500000000,
					"makeMigratable": true,
					"shared": false
			},
			{
					"name": "config",
					"base": "/home/ec2-user/out/package/config.json",
					"overlay": "/home/ec2-user/out/instance-0/overlay/config.json",
					"state": "/home/ec2-user/out/instance-0/state/config.json",
					"blockSize": 65536,
					"expiry": 1000000000,
					"maxDirtyBlocks": 200,
					"minCycles": 5,
					"maxCycles": 20,
					"cycleThrottle": 500000000,
					"makeMigratable": true,
					"shared": false
			},
			{
					"name": "oci",
					"base": "/home/ec2-user/out/package/oci.ext4",
					"overlay": "/home/ec2-user/out/instance-0/overlay/oci.ext4",
					"state": "/home/ec2-user/out/instance-0/state/oci.ext4",
					"blockSize": 65536,
					"expiry": 1000000000,
					"maxDirtyBlocks": 200,
					"minCycles": 5,
					"maxCycles": 20,
					"cycleThrottle": 500000000,
					"makeMigratable": true,
					"shared": false
			}
	]`))

	println(peerCmd.String())
	peerCmd.Stdout = logManager.logFiles["peer"]
	peerCmd.Stderr = logManager.logFiles["peer"]

	if err := peerCmd.Start(); err != nil {
		peerLogger.Printf("Error starting peer service: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to start peer service"})
		return
	}

	peerLogger.Printf("Waiting 5 seconds for peer to initialize")
	time.Sleep(5 * time.Second)

	// Start forwarder
	forwarderLogger, err := logManager.GetLogger("forwarder")
	if err != nil {
		log.Printf("Error creating forwarder logger: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("Failed to create forwarder logger: %v", err)})
		return
	}

	forwarderLogger.Printf("Starting forwarder")
	forwarderCmd := exec.Command("drafter-forwarder", "--port-forwards", fmt.Sprintf(`[{"netns":"ark0","internalPort":"6379","protocol":"tcp","externalAddr":"127.0.0.1:3333"}]`))

	forwarderCmd.Stdout = logManager.logFiles["forwarder"]
	forwarderCmd.Stderr = logManager.logFiles["forwarder"]

	if err := forwarderCmd.Start(); err != nil {
		forwarderLogger.Printf("Error starting forwarder: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to start forwarder"})
		return
	}

	forwarderLogger.Printf("VM started successfully: %s", name)
	c.JSON(http.StatusOK, gin.H{
		"message":   "VM started",
		"name":      name,
		"logs_path": logManager.baseDir,
	})
}

func (api *DrafterAPI) stopVM(c *gin.Context) {
	name := c.Param("name")
	log.Printf("Stopping VM: %s", name)

	// Stop all drafter services for this VM
	cmd := exec.Command("pkill", "-f", fmt.Sprintf("ark-%s", name))
	if out, err := runCommandWithOutput(cmd); err != nil {
		log.Printf("Error stopping services: %v", err)
	} else {
		log.Printf("Services stopped: %s", out)
	}

	log.Printf("VM stopped successfully: %s", name)
	c.JSON(http.StatusOK, gin.H{"message": "VM stopped", "name": name})
}

func (api *DrafterAPI) getVMStatus(c *gin.Context) {
	name := c.Param("name")
	log.Printf("Getting status for VM: %s", name)

	// Check if services are running
	natRunning := exec.Command("pgrep", "-f", "drafter-nat").Run() == nil
	peerRunning := exec.Command("pgrep", "-f", fmt.Sprintf("ark-%s.*drafter-peer", name)).Run() == nil
	forwarderRunning := exec.Command("pgrep", "-f", fmt.Sprintf("ark-%s.*drafter-forwarder", name)).Run() == nil

	status := gin.H{
		"name": name,
		"services": gin.H{
			"nat":       natRunning,
			"peer":      peerRunning,
			"forwarder": forwarderRunning,
		},
	}

	log.Printf("Status for VM %s: %v", name, status)
	c.JSON(http.StatusOK, status)
}

func (api *DrafterAPI) migrateVM(c *gin.Context) {
	name := c.Param("name")
	var config struct {
		SourceIP string `json:"source_ip"`
	}
	if err := c.BindJSON(&config); err != nil {
		log.Printf("Error parsing migration request: %v", err)
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// Setup logging
	logManager, err := api.setupLogging(name)
	if err != nil {
		log.Printf("Error setting up logging: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("Failed to setup logging: %v", err)})
		return
	}
	defer logManager.Close()

	// Set up peer service logging
	peerLogger, err := logManager.GetLogger("peer")
	if err != nil {
		log.Printf("Error creating peer logger: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("Failed to create peer logger: %v", err)})
		return
	}

	peerLogger.Printf("Starting migration for VM %s from source IP %s", name, config.SourceIP)

	// Create instance directory
	cmd := exec.Command("sudo", "mkdir", "-p",
		"/home/ec2-user/out/instance-0/overlay",
		"/home/ec2-user/out/instance-0/state")
	if out, err := runCommandWithOutput(cmd); err != nil {
		peerLogger.Printf("Error creating instance directories: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("Failed to create instance directories: %v", err)})
		return
	} else {
		peerLogger.Printf("Created instance directories: %s", out)
	}

	// Start peer service for migration
	peerLogger.Printf("Starting peer service for migration")
	peerCmd := exec.Command("sudo", "drafter-peer", "--netns", "ark0", "--raddr", fmt.Sprintf("%s:1337", config.SourceIP), "--laddr", "", "--devices", `[
			{
					"name": "state",
					"base": "/home/ec2-user/out/package/state.bin",
					"overlay": "/home/ec2-user/out/instance-0/overlay/state.bin",
					"state": "/home/ec2-user/out/instance-0/state/state.bin",
					"blockSize": 65536,
					"expiry": 1000000000,
					"maxDirtyBlocks": 200,
					"minCycles": 5,
					"maxCycles": 20,
					"cycleThrottle": 500000000,
					"makeMigratable": true,
					"shared": false
			},
			{
					"name": "memory",
					"base": "/home/ec2-user/out/package/memory.bin",
					"overlay": "/home/ec2-user/out/instance-0/overlay/memory.bin",
					"state": "/home/ec2-user/out/instance-0/state/memory.bin",
					"blockSize": 65536,
					"expiry": 1000000000,
					"maxDirtyBlocks": 200,
					"minCycles": 5,
					"maxCycles": 20,
					"cycleThrottle": 500000000,
					"makeMigratable": true,
					"shared": false
			},
			{
					"name": "kernel",
					"base": "/home/ec2-user/out/package/vmlinux",
					"overlay": "/home/ec2-user/out/instance-0/overlay/vmlinux",
					"state": "/home/ec2-user/out/instance-0/state/vmlinux",
					"blockSize": 65536,
					"expiry": 1000000000,
					"maxDirtyBlocks": 200,
					"minCycles": 5,
					"maxCycles": 20,
					"cycleThrottle": 500000000,
					"makeMigratable": true,
					"shared": false
			},
			{
					"name": "disk",
					"base": "/home/ec2-user/out/package/rootfs.ext4",
					"overlay": "/home/ec2-user/out/instance-0/overlay/rootfs.ext4",
					"state": "/home/ec2-user/out/instance-0/state/rootfs.ext4",
					"blockSize": 65536,
					"expiry": 1000000000,
					"maxDirtyBlocks": 200,
					"minCycles": 5,
					"maxCycles": 20,
					"cycleThrottle": 500000000,
					"makeMigratable": true,
					"shared": false
			},
			{
					"name": "config",
					"base": "/home/ec2-user/out/package/config.json",
					"overlay": "/home/ec2-user/out/instance-0/overlay/config.json",
					"state": "/home/ec2-user/out/instance-0/state/config.json",
					"blockSize": 65536,
					"expiry": 1000000000,
					"maxDirtyBlocks": 200,
					"minCycles": 5,
					"maxCycles": 20,
					"cycleThrottle": 500000000,
					"makeMigratable": true,
					"shared": false
			},
			{
					"name": "oci",
					"base": "/home/ec2-user/out/package/oci.ext4",
					"overlay": "/home/ec2-user/out/instance-0/overlay/oci.ext4",
					"state": "/home/ec2-user/out/instance-0/state/oci.ext4",
					"blockSize": 65536,
					"expiry": 1000000000,
					"maxDirtyBlocks": 200,
					"minCycles": 5,
					"maxCycles": 20,
					"cycleThrottle": 500000000,
					"makeMigratable": true,
					"shared": false
			}
	]`)

	// Set up logging before starting the command
	peerCmd.Stdout = logManager.logFiles["peer"]
	peerCmd.Stderr = logManager.logFiles["peer"]

	if err := peerCmd.Start(); err != nil {
		peerLogger.Printf("Error starting peer service: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to start peer service"})
		return
	}

	peerLogger.Printf("Waiting 5 seconds for peer to initialize")
	time.Sleep(5 * time.Second)

	// Set up forwarder logging
	forwarderLogger, err := logManager.GetLogger("forwarder")
	if err != nil {
		log.Printf("Error creating forwarder logger: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("Failed to create forwarder logger: %v", err)})
		return
	}

	// Start forwarder
	forwarderLogger.Printf("Starting forwarder")
	forwarderCmd := exec.Command("sudo", "drafter-forwarder", "--port-forwards",
		`[{"netns":"ark0","internalPort":"6379","protocol":"tcp","externalAddr":"127.0.0.1:3334"}]`)

	// Set up logging before starting the command
	forwarderCmd.Stdout = logManager.logFiles["forwarder"]
	forwarderCmd.Stderr = logManager.logFiles["forwarder"]

	if err := forwarderCmd.Start(); err != nil {
		forwarderLogger.Printf("Error starting forwarder: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to start forwarder"})
		return
	}

	forwarderLogger.Printf("Migration initiated for VM: %s", name)
	c.JSON(http.StatusOK, gin.H{
		"message":   "Migration initiated",
		"name":      name,
		"source":    config.SourceIP,
		"status":    "migrating",
		"logs_path": logManager.baseDir,
	})
}
func main() {
	log.Printf("Starting Drafter API server")
	api := NewDrafterAPI()
	if err := api.router.Run(":8080"); err != nil {
		log.Fatal(err)
	}
}
