package main

import (
	"fmt"
	"os"

	"glance/routes"
	"glance/store/binance"
	"glance/store/menu"

	mingfuflags "github.com/Fu-XDU/mingfu_go_common/flags"
	"github.com/labstack/gommon/log"
	"github.com/urfave/cli/v2"
)

const (
	clientIdentifier = "glance"
	clientVersion    = "1.0.0"
	clientUsage      = "Glance menu bar API server"
)

var (
	app = cli.NewApp()
)

func init() {
	app.Action = ServerApp
	app.Name = clientIdentifier
	app.Version = clientVersion
	app.Usage = clientUsage
	app.Commands = []*cli.Command{}
	app.Flags = append(app.Flags, mingfuflags.GinFlags...)
	app.Flags = append(app.Flags,
		&cli.StringFlag{
			Name:  "menu-config",
			Value: "config/menu.json",
			Usage: "Path to menu JSON config file",
		},
	)
}

func ServerApp(ctx *cli.Context) error {
	if args := ctx.Args(); args.Len() > 0 {
		return fmt.Errorf("invalid command: %q", args.First())
	}
	err := prepare(ctx)
	if err != nil {
		log.Error(err)
	}
	return err
}

func prepare(ctx *cli.Context) (err error) {
	menu.SetConfigPath(ctx.String("menu-config"))

	binanceCfg, err := menu.LoadBinanceConfig()
	if err != nil {
		return fmt.Errorf("load binance config: %w", err)
	}

	binance.Configure(binanceCfg)
	binance.Start()
	routes.Run()
	return
}

func main() {
	if err := app.Run(os.Args); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
