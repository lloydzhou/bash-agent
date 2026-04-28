package main

import (
	"fmt"
	"os"

	"github.com/lloydzhou/bash-agent/internal/app"
)

func main() {
	if err := app.Run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr); err != nil {
		fmt.Fprintf(os.Stderr, "\033[31mError: %s\033[0m\n", err)
		os.Exit(1)
	}
}
