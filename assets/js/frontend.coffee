#= require ../intertwinkles/js/intertwinkles/index

intertwinkles.build_toolbar($("header"), {applabel: "resolve"})
intertwinkles.build_footer($("footer"))

resolve = {}

class Proposal extends Backbone.Model
  idAttribute: "_id"
class ProposalCollection extends Backbone.Collection
  model: Proposal
  comparator: (p) ->
    return new Date(p.get("revisions")[0].date).getTime()

load_proposal_data = (data) ->
  if not resolve.model?
    resolve.model = new Proposal()
  resolve.model.set(data)
if INITIAL_DATA.proposal?
  load_proposal_data(INITIAL_DATA.proposal)

handle_error = (data) ->
  flash "error", "Oh golly, but the server has errored. So sorry."
  console.info(data)

class BaseView extends Backbone.View
  softNav: (event) =>
    event.preventDefault()
    resolve.app.navigate($(event.currentTarget).attr("href"), {
      trigger: true
    })
  initialize: ->
    @views = []

  remove: =>
    if @views?
      view.remove() for view in @views
    super()

  addView: (selector, view) =>
    @$(selector).html(view.el)
    view.render()
    @views.push(view)

  validateFields: (container, selectors) =>
    cleaned_data = {}
    dirty = false
    $(".error", container).removeClass("error")
    $(".error-msg", container).remove()
    for [selector, test, msg] in selectors
      el = @$(selector)
      if el.attr("type") == "checkbox"
        val = el.is(":checked")
      else
        val = el.val()

      clean = test(val)
      if clean?
        cleaned_data[el.attr("name")] = clean
      else
        dirty = true
        parent = el.closest(".control-group")
        parent.addClass("error")
        parent.find(".controls").append(
          "<span class='error-msg help-inline'>#{msg}</span>"
        )
    if dirty
      return false
    return cleaned_data

BaseEvents = {
  'click .softnav': 'softNav'
}

class SplashView extends BaseView
  template: _.template($("#splashTemplate").html())
  itemTemplate: _.template($("#listedProposalTemplate").html())
  events: _.extend {
  }, BaseEvents
  
  initialize: ->
    intertwinkles.user.on "change", @getProposalList
    super()

  remove: =>
    intertwinkles.user.off "change", @getProposalList
    super()

  render: =>
    @$el.html(@template())

  getProposalList: =>
    intertwinkles.socket.on "list_proposals", (data) =>
      if data.error?
        flash "error", "The server. It has got confused."
        console.info(data.error)

class AddProposalView extends BaseView
  template: _.template($("#addProposalTemplate").html())
  events: _.extend {
    'submit   form': 'saveProposal'
  }, BaseEvents

  initialize: ->
    intertwinkles.user.on("change", @onUserChange)
    super()

  remove: =>
    intertwinkles.user.off("change", @onUserChange)
    super()

  onUserChange: =>
    val = @$("textarea").val()
    @render()
    @$("textarea").val(val)

  render: =>
    @$el.html(@template())
    @sharing = new intertwinkles.SharingFormControl()
    @addView(".group-choice", @sharing)

  saveProposal: (event) =>
    event.preventDefault()
    # Validate fields.
    cleaned_data = @validateFields "form", [
      ["#id_proposal", ((val) -> val or null), "This field is required."]
    ]
    if cleaned_data == false
      return
    
    # Upload form. 
    @$("[type=submit]").addClass("loading")
    cleaned_data['sharing'] = @sharing.sharing

    intertwinkles.once "proposal_saved", (data) ->
      return handle_error(data) if data.error?
      @$("[type=submit]").removeClass("loading")
      load_proposal_data(data.proposal)

    intertwinkles.socket.emit "save_proposal", {
      callback: "proposal_saved"
      proposal: cleaned_data
      action: "create"
    }

class Router extends Backbone.Router
  routes:
    'p/:id/':   'room'
    'new/':        'newProposal'
    '':           'index'

  index: =>
    @_display(new SplashView())

  newProposal: =>
    @_display(new AddProposalView())

  room: (id) =>
    @_dipslay(new ShowProposalView(id: id))

  _display: (view) =>
    @view?.remove()
    $("#app").html(view.el)
    view.render()
    @view = view


socket = io.connect("/iorooms")
socket.on "error", (data) ->
  flash "error", "Oh noes, server error."
  window.console?.log?(data.error)

socket.on "connect", ->
  intertwinkles.socket = socket
  unless resolve.started == true
    resolve.app = new Router()
    Backbone.history.start(pushState: true)
    resolve.started = true
