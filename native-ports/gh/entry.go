// Build inside the pinned cli/cli module so the stock api command is reused.
package main

import "C"

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"syscall"
	"unsafe"

	"github.com/cli/cli/v2/internal/build"
	"github.com/cli/cli/v2/internal/gh"
	"github.com/cli/cli/v2/internal/ghrepo"
	"github.com/cli/cli/v2/pkg/cmd/api"
	"github.com/cli/cli/v2/pkg/cmd/version"
	"github.com/cli/cli/v2/pkg/cmdutil"
	"github.com/cli/cli/v2/pkg/iostreams"
	"github.com/spf13/cobra"
)

const host = "github.com"

var missingToken = errors.New("set GH_TOKEN to authenticate to github.com")

// The pinned upstream api command consumes only Authentication on Config,
// and only these four AuthConfig methods. No desktop configuration, keyring,
// token refresh, subprocess, or host environment mutation is needed.
type config struct {
	gh.Config
	auth *authConfig
}

func (c config) Authentication() gh.AuthConfig { return c.auth }

type authConfig struct {
	gh.AuthConfig
	token string
}

func (c *authConfig) DefaultHost() (string, string)      { return host, "embedded" }
func (*authConfig) APIHostForHost(string) (string, bool) { return "", false }
func (*authConfig) HostForAPIHost(string) (string, bool) { return "", false }

func (c *authConfig) ActiveTokenWithRefresh(name string) (gh.Credential, gh.RefreshStatus, error) {
	if name == host {
		return gh.Credential{Token: c.token}, gh.RefreshStatusInapplicable, nil
	}
	return gh.Credential{}, gh.RefreshStatusInapplicable, nil
}

func duplicate(fd C.int, name string) (*os.File, error) {
	newFD, err := syscall.Dup(int(fd))
	if err != nil {
		return nil, err
	}
	syscall.CloseOnExec(newFD)
	return os.NewFile(uintptr(newFD), name), nil
}

func command(args []string, input, output, diagnostics *os.File, token, repo, hostname string) int {
	streams := iostreams.System()
	streams.In, streams.Out, streams.ErrOut = input, output, diagnostics
	streams.SetPager("")
	streams.SetStdinTTY(false)
	streams.SetStdoutTTY(false)
	streams.SetStderrTTY(false)
	streams.SetColorEnabled(false)
	streams.SetNeverPrompt(true)
	streams.SetSpinnerDisabled(true)
	streams.SetContentSanitization(true)

	f := &cmdutil.Factory{
		AppVersion: build.Version,
		IOStreams:  streams,
		Config:     func() (gh.Config, error) { return config{auth: &authConfig{token: token}}, nil },
		BaseRepo: func() (ghrepo.Interface, error) {
			if repo == "" {
				return nil, errors.New("set GH_REPO or use an explicit API path")
			}
			return ghrepo.FromFullNameWithHost(repo, host)
		},
		Branch: func() (string, error) { return "", errors.New("use an explicit branch name") },
	}
	root := &cobra.Command{
		Use:           "gh",
		Short:         "GitHub CLI API client for a-Shell",
		Version:       strings.TrimSpace(version.Format(build.Version, build.Date)),
		SilenceErrors: true,
		SilenceUsage:  true,
	}
	root.SetVersionTemplate("{{.Version}}\n")
	root.SetIn(input)
	root.SetOut(output)
	root.SetErr(diagnostics)
	root.SetArgs(args)
	child := api.NewCmdApi(f, nil)
	// Use the command-scoped GH_REPO captured by ios_system rather than reading
	// the Go runtime's process environment via the desktop PreRun hook.
	child.PreRun = nil
	child.PreRunE = func(cmd *cobra.Command, _ []string) error {
		selected, err := cmd.Flags().GetString("hostname")
		if err != nil {
			return err
		}
		if selected == "" {
			selected = hostname
		}
		if selected != "" && !strings.EqualFold(selected, host) {
			return errors.New("embedded gh supports github.com only")
		}
		if token == "" {
			return missingToken
		}
		return nil
	}
	root.AddCommand(child)
	err := root.Execute()
	if err != nil {
		fmt.Fprintln(diagnostics, "gh:", err)
		if errors.Is(err, missingToken) {
			return 4
		}
		return 1
	}
	return 0
}

//export gh_embedded_run
func gh_embedded_run(argc C.int, argv **C.char, inFD, outFD, errFD C.int, token, repo, hostname *C.char) (status C.int) {
	diagnostics, err := duplicate(errFD, "a-Shell stderr")
	if err != nil {
		return 1
	}
	defer diagnostics.Close()
	defer func() {
		if recover() != nil {
			fmt.Fprintln(diagnostics, "gh: unexpected failure")
			status = 1
		}
	}()
	input, err := duplicate(inFD, "a-Shell stdin")
	if err != nil {
		fmt.Fprintln(diagnostics, "gh: could not open command input")
		return 1
	}
	defer input.Close()
	output, err := duplicate(outFD, "a-Shell stdout")
	if err != nil {
		fmt.Fprintln(diagnostics, "gh: could not open command output")
		return 1
	}
	defer output.Close()

	args := make([]string, 0, int(argc)-1)
	for _, arg := range unsafe.Slice(argv, int(argc))[1:] {
		args = append(args, C.GoString(arg))
	}
	return C.int(command(args, input, output, diagnostics, C.GoString(token), C.GoString(repo), C.GoString(hostname)))
}

func main() {}
