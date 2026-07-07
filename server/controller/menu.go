package controller

import (
	"net/http"

	"glance/store/menu"

	"github.com/gin-gonic/gin"
)

func GetMenu(c *gin.Context) {
	resp, err := menu.LoadResponse()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to load menu config"})
		return
	}
	c.JSON(http.StatusOK, resp)
}
