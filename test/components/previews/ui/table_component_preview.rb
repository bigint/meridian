class Ui::TableComponentPreview < ViewComponent::Preview
  Row = Data.define(:name, :version, :state)

  def default
    rows = [ Row.new("ap-south-1a-web-1", "v42", "in_sync"), Row.new("eu-west-1b-web-2", "v41", "drifted"), Row.new("us-east-1a-web-3", nil, "missing") ]
    render_with_template(locals: { rows: rows })
  end

  def empty
    render_with_template(template: "ui/table_component_preview/default", locals: { rows: [] })
  end
end
