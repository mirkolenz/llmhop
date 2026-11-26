package sysstat

import (
	"bytes"
	"encoding/xml"
	"errors"
	"strconv"
)

// decodePlist decodes an XML property list into maps, slices, strings,
// numbers and booleans, keeping data and dates as their text.
func decodePlist(data []byte) (any, error) {
	d := xml.NewDecoder(bytes.NewReader(data))

	for {
		tok, err := d.Token()
		if err != nil {
			return nil, err
		}

		if start, ok := tok.(xml.StartElement); ok && start.Name.Local != "plist" {
			return plistValue(d, start)
		}
	}
}

// plistValue decodes the value that start opens.
func plistValue(d *xml.Decoder, start xml.StartElement) (any, error) {
	switch start.Name.Local {
	case "dict":
		dict := make(map[string]any)

		for key := ""; ; {
			tok, err := d.Token()
			if err != nil {
				return nil, err
			}

			switch tok := tok.(type) {
			case xml.EndElement:
				return dict, nil
			case xml.StartElement:
				if tok.Name.Local == "key" {
					if err := d.DecodeElement(&key, &tok); err != nil {
						return nil, err
					}

					continue
				}

				v, err := plistValue(d, tok)
				if err != nil {
					return nil, err
				}

				dict[key] = v
			}
		}
	case "array":
		var array []any

		for {
			tok, err := d.Token()
			if err != nil {
				return nil, err
			}

			switch tok := tok.(type) {
			case xml.EndElement:
				return array, nil
			case xml.StartElement:
				v, err := plistValue(d, tok)
				if err != nil {
					return nil, err
				}

				array = append(array, v)
			}
		}
	case "true", "false":
		return start.Name.Local == "true", d.Skip()
	}

	var text string

	if err := d.DecodeElement(&text, &start); err != nil {
		return nil, err
	}

	switch start.Name.Local {
	case "integer", "real":
		return strconv.ParseFloat(text, 64)
	case "string", "data", "date":
		return text, nil
	}

	return nil, errors.New("unknown plist element " + start.Name.Local)
}
