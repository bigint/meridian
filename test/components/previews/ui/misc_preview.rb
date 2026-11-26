class Ui::MiscPreview < ViewComponent::Preview
  def avatars
    render_with_template
  end

  def code_block
    render Ui::CodeBlockComponent.new(label: ".kamal/secrets", code: "MERIDIAN_TOKEN=$MERIDIAN_TOKEN\nKAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD")
  end
end
