express       = require 'express'
socketio      = require 'socket.io'
intertwinkles = require 'node-intertwinkles'
RoomManager   = require('iorooms').RoomManager
RedisStore    = require('connect-redis')(express)
_             = require 'underscore'
mongoose      = require 'mongoose'
schema        = require './schema'

start = (config) ->
  db = mongoose.connect(
    "mongodb://#{config.dbhost}:#{config.dbport}/#{config.dbname}"
  )
  app = express.createServer()
  sessionStore = new RedisStore()
  io = socketio.listen(app, {"log level": 0})
  iorooms = new RoomManager("/iorooms", io, sessionStore)
  io.of("/iorooms").setMaxListeners(15)
  intertwinkles.attach(config, app, iorooms)

  #
  # Config
  #
  app.use require('connect-assets')()
  app.use express.bodyParser()
  app.use express.cookieParser()
  app.use express.session {
    secret: config.secret
    key: 'express.sid'
    store: sessionStore
  }
  app.set 'view engine', 'jade'
  app.set 'view options', {layout: false}

  app.configure 'development', ->
      app.use '/static', express.static(__dirname + '/../assets')
      app.use '/static', express.static(__dirname + '/../node_modules/node-intertwinkles/assets')
      app.use express.errorHandler {dumpExceptions: true, showStack: true}

  app.configure 'production', ->
    # Cache long time in production.
    app.use '/static', express.static(__dirname + '/../assets', { maxAge: 1000*60*60*24 })
    app.use '/static', express.static(__dirname + '/../node_modules/node-intertwinkles/assets', { maxAge: 1000*60*60*24 })

  #
  # Routes
  #
  
  context = (req, obj, initial_data) ->
    return _.extend({
      initial_data: _.extend({
        email: req?.session?.auth?.email or null
        groups: req?.session?.groups or null
      }, initial_data or {})
      conf: {
        api_url: config.intertwinkles.api_url
        apps: config.intertwinkles.apps
      }
      flash: req.flash()
    }, obj)

  index_res = (req, res, extra_context) ->
    res.render 'index', context(req, extra_context or {})

  app.get "/", (req, res) ->
    index_res(req, res, {
      title: "Resolve: Decide Something"
    })

  app.get "/new/", (req, res) ->
    index_res(req, res, {
      title: "New proposal"
    })

  app.get "/p/:id/", (req, res) ->
    index_res(req, res, {
      title: "Resolve: The Proposal's Name"
    })

  iorooms.onChannel "get_proposal_list", (socket, data) ->

  iorooms.onChannel "get_proposal", (socket, data) ->

  iorooms.onChannel "save_proposal", (socket, data) ->
    async.waterfall [
      # Fetch the proposal.
      (done) ->
        if data.proposal._id?
          schema.Proposal.findOne {_id: data.proposal._id}, (err, proposal) ->
            return done(err) if err?
            if intertwinkles.can_edit(socket.session, proposal)
              done(null, proposal)
            else
              done("Permission denied.")
        else
          done(null, new schema.Proposal())

      # Update and save it. 
      (proposal, done) ->
        switch data.action

          # Change the proposal.
          when "create", "update"
            return done("Missing proposal data.") unless data.proposal?

            # Update sharing.
            if data.proposal?.sharing?
              unless intertwinkles.can_change_sharing(socket.session, proposal)
                return done("Not allowed to change sharing.")
              unless socket.session.groups.groups[data.proposal.sharing.group_id]?
                return done("Unauthorized group")
              proposal.sharing = data.proposal.sharing

            # Add a revision.
            if data.proposal?.proposal?
              if intertwinkles.is_authenticated()
                name = socket.session.groups.users[socket.session.auth.user_id].name
              else
                name = data.proposal.name
              proposal.revisions.push [{
                user_id: socket.session.auth.user_id
                name: name
                text: data.proposal.proposal
              }]
            if proposal.revisions.length == 0
              return done("Missing proposal field.")

            # Finalize the proposal.
            if data.proposal?.passed?
              proposal.passed = data.proposal.passed
              proposal.resolved = new Date()

            proposal.save (err, doc) ->
              return done(err, doc, null)

          # Add a vote.
          when "append"
            return done("Missing opinion text") unless data.opinion?.text
            return done("Missing vote") unless data.opinion?.vote
            if data.opinion?.user_id
              user_id = data.opinion.user_id
              user = socket.session.groups.users[user_id]
              return done("Unauthorized user id") unless user?
              name = user.name
            else
              user_id = null
              name = data.opinion.name

            if user_id?
              opinion_set = _.find proposal.opinions, (o) ->
                o.user_id == user_id
            else
              opinion_set = _.find proposal.opinions, (o) ->
                (not o.user_id?) and o.name == name
            if not opinion_set
              opinion_set = {
                user_id: user_id
                name: name
                revisions: []
              }
              proposal.opinions.push(opinion_set)
            opinion_set.revisions.push([
              text: data.opinion.text
              vote: data.opinion.vote
            ])
            proposal.save (err, doc) ->
              return done(err, null, opinion_set)

    ], (err, proposal, opinion_set) ->
      if err?
        if data.callback?
          return socket.emit data.callback, {error: err}
        else
          return socket.emit "error", {error: err}

      emittal = { proposal: proposal, opinion_set: opinion_set }
      socket.broadcast.to(proposal.id, emittal)
      socket.emit(data.callback, emittal) if data.callback?

  intertwinkles.attach(config, app, iorooms)

  app.listen (config.port)

module.exports = {start}
