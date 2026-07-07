package routes

import (
	mingfuflags "github.com/Fu-XDU/mingfu_go_common/flags"
	mingfuroutes "github.com/Fu-XDU/mingfu_go_common/routes"
	"github.com/gin-gonic/gin"
)

// Run will start the server
func Run() {
	mingfuroutes.Run(mingfuflags.ServerPort, mingfuflags.SslCertPath, mingfuflags.SslKeyPath, mingfuflags.TrustedProxies, getRoutes)
}

func getRoutes(router *gin.Engine) {
	router.Use(allowCors)
	addMenuRoutes(router)
}
