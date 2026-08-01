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

func GetPricesText(c *gin.Context) {
	c.Data(http.StatusOK, "text/plain; charset=utf-8", []byte(menu.FormatPricesText()))
}
