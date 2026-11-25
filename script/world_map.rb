# Regenerates app/assets/images/world.svg from Natural Earth's public-domain
# 110m land outlines, in WorldMap's projection:
#
#   curl -fsSLO https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_land.geojson
#   bin/rails runner script/world_map.rb ne_110m_land.geojson
geojson = JSON.parse(File.read(ARGV.fetch(0)))

rings = geojson["features"].flat_map do |feature|
  geometry = feature["geometry"]
  polygons = geometry["type"] == "Polygon" ? [ geometry["coordinates"] ] : geometry["coordinates"]
  polygons.flat_map { it }
end

d = rings.filter_map do |ring|
  points = ring.map { |lng, lat| WorldMap.project(lat, lng) }.chunk_while { |a, b| a == b }.map(&:first)
  next if points.size < 3
  "M" + points.map { |x, y| "#{x} #{y}" }.join("L") + "Z"
end.join

svg = <<~SVG
  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{WorldMap::WIDTH.to_i} #{WorldMap::HEIGHT}">
    <!-- Land outlines: Natural Earth 1:110m, public domain (naturalearthdata.com). -->
    <symbol id="land" viewBox="0 0 #{WorldMap::WIDTH.to_i} #{WorldMap::HEIGHT}"><path fill="currentColor" d="#{d}"/></symbol>
    <use href="#land"/>
  </svg>
SVG
File.write(Rails.root.join("app/assets/images/world.svg"), svg)
puts "Wrote world.svg: #{rings.size} rings, #{svg.bytesize / 1024} KB"
