base_config = require '../base_config'
_           = require 'underscore'

conf = _.extend {}, base_config
conf.port = 9001
conf.intertwinkles.api_key = "one"
conf.dbname = "resolve"
module.exports = conf
