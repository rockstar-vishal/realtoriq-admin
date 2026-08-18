# frozen_string_literal: true

# The masters screens are generated from each controller's column definitions,
# so the views need help rendering a cell without knowing the model.
# Path building lives on the controller — see Admin::Masters::BaseController.
module MastersHelper
  def master_cell_value(record, column)
    value = record.public_send(column[:key])

    case column[:type]
    when :boolean
      value ? tag.span("Yes", class: "tag tag-accent") : tag.span("No", class: "tag tag-neutral")
    when :association
      associated = record.public_send(column[:key].to_s.delete_suffix("_id"))
      blank_dash(associated&.public_send(column[:display] || :name))
    when :select
      blank_dash(value&.humanize)
    else
      blank_dash(value)
    end
  end
end
