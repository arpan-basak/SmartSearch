import 'package:flutter_test/flutter_test.dart';
import 'package:smart_search_app/features/documents/domain/document_intelligence.dart';

void main() {
  test('certificate intent outranks an IRCTC ticket with incidental word', () {
    final certificate = DocumentIntelligence.infer(
      name: 'IMG_2025.pdf',
      mimeType: 'application/pdf',
      content: 'Certificate of Completion. This is to certify that Arpan has '
          'successfully completed the Frontend Development Bootcamp.',
    );
    final ticket = DocumentIntelligence.infer(
      name: 'rail.pdf',
      mimeType: 'application/pdf',
      content:
          'IRCTC e-ticket PNR 1234567890 train number 12601 passenger fare. '
          'Carry the original identity certificate during the journey.',
    );

    expect(certificate.category, 'certificate');
    expect(ticket.category, 'travel_ticket');
    final certificateScore = DocumentIntelligence.score(
      query: 'my workshop certificates',
      name: 'IMG_2025.pdf',
      mimeType: 'application/pdf',
      content: 'Certificate of Completion for a frontend bootcamp workshop',
      profile: certificate,
    );
    final ticketScore = DocumentIntelligence.score(
      query: 'my workshop certificates',
      name: 'rail.pdf',
      mimeType: 'application/pdf',
      content: 'IRCTC PNR train fare identity certificate journey',
      profile: ticket,
    );
    expect(certificateScore, greaterThan(ticketScore));
    expect(ticketScore, 0);
  });

  test('natural assignment query prefers matching assignment context', () {
    final assignment = DocumentIntelligence.infer(
      name: 'DA2.docx',
      mimeType:
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      content: 'Digital Assignment 2 Frontend Development submitted by Arpan',
    );
    expect(assignment.category, 'assignment');
    expect(
      DocumentIntelligence.score(
        query: 'assignment two for front end',
        name: 'DA2.docx',
        mimeType:
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        content: 'Digital Assignment 2 Frontend Development submitted by Arpan',
        profile: assignment,
      ),
      greaterThan(600),
    );
  });

  test('explicit flight search rejects an unrelated generic document', () {
    const generic = DocumentContextProfile(
      category: 'document',
      confidence: 0.25,
      summary: 'Backup note',
      keywords: <String>['backup', 'note'],
    );
    expect(
      DocumentIntelligence.score(
        query: 'flight tickets from Kolkata to Delhi on 2026-07-14',
        name: 'Backup.note',
        mimeType: 'application/octet-stream',
        content: 'Device backup settings and application notes',
        profile: generic,
        semanticSimilarity: 0.7,
      ),
      0,
    );
  });

  test('syllabus search rejects a generic note without syllabus evidence', () {
    final genericNote = DocumentIntelligence.infer(
      name: 'Untitled File',
      mimeType: 'text/plain',
      content: 'Type your notes or document here. Save your tutorial ideas.',
    );
    expect(genericNote.category, 'study_material');
    expect(
      DocumentIntelligence.score(
        query: 'syllabus',
        name: 'Untitled File',
        mimeType: 'text/plain',
        content: 'Type your notes or document here. Save your tutorial ideas.',
        profile: genericNote,
        semanticSimilarity: 0.9,
      ),
      0,
    );

    final syllabus = DocumentIntelligence.infer(
      name: 'BCA syllabus 2026.pdf',
      mimeType: 'application/pdf',
      content: 'Curriculum and course outline for semester one.',
    );
    expect(syllabus.category, 'study_material');
    expect(
      DocumentIntelligence.score(
        query: 'syllabus',
        name: 'BCA syllabus 2026.pdf',
        mimeType: 'application/pdf',
        content: 'Curriculum and course outline for semester one.',
        profile: syllabus,
      ),
      greaterThan(0),
    );
  });

  test('incidental boarding language does not classify a book as a ticket', () {
    final book = DocumentIntelligence.infer(
      name: 'Novel.pdf',
      mimeType: 'application/pdf',
      content: 'A memoir about childhood, boarding school, memory and art.',
    );
    expect(book.category, 'document');
  });

  test('finds a class 12 marksheet from OCR content, not its filename', () {
    final marksheet = DocumentIntelligence.infer(
      name: 'IMG_004827.pdf',
      mimeType: 'application/pdf',
      content: 'Central Board of Secondary Education Statement of Marks '
          'Senior School Certificate Examination Class XII subject code '
          'maximum marks marks obtained result pass',
    );
    expect(marksheet.category, 'education_record');
    expect(
      DocumentIntelligence.score(
        query: 'my 12 board exam marksheet',
        name: 'IMG_004827.pdf',
        mimeType: 'application/pdf',
        content: 'Board examination class XII statement of marks result',
        profile: marksheet,
      ),
      greaterThan(600),
    );
  });

  test('train route rejects a flight ticket and tolerates route spelling', () {
    final train = DocumentIntelligence.infer(
      name: '8F3A91.pdf',
      mimeType: 'application/pdf',
      content: 'IRCTC e-ticket PNR train number journey from Katpadi to '
          'Perambur passenger coach berth fare',
    );
    final flight = DocumentIntelligence.infer(
      name: 'air tickets.pdf',
      mimeType: 'application/pdf',
      content: 'Airline flight ticket boarding pass from Chennai to Delhi',
    );
    final trainScore = DocumentIntelligence.score(
      query: 'train ticket from Katpadi to Preambur',
      name: '8F3A91.pdf',
      mimeType: 'application/pdf',
      content: 'IRCTC train journey from Katpadi to Perambur',
      profile: train,
    );
    final flightScore = DocumentIntelligence.score(
      query: 'train ticket from Katpadi to Preambur',
      name: 'air tickets.pdf',
      mimeType: 'application/pdf',
      content: 'Airline flight boarding pass from Chennai to Delhi',
      profile: flight,
    );
    expect(trainScore, greaterThan(flightScore));
    expect(flightScore, 0);
  });
}
