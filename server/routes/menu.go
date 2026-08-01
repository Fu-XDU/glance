package routes

import (
	"glance/controller"

	"github.com/gin-gonic/gin"
)

func addMenuRoutes(router *gin.Engine) {
	api := router.Group("/api")
	api.GET("/menu", controller.GetMenu)
	api.GET("/prices", controller.GetPricesText)
}
